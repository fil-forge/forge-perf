#!/usr/bin/env python3
"""Sends a finished run's results, and a traced run's scrubbed spans, to an
OTLP/HTTP endpoint on this machine: the Grafana step's collector, which
forwards them to Grafana Cloud.

    grafana-export.py --endpoint URL --runner runner.json
                      [--record record.json] [--traces traces.jsonl]
                      --span-attributes FILE [--max-request-bytes N]
                      [--deadline SECONDS]

docs/runner.md ("Grafana") is the contract. The endpoint is plain http:// on
this machine and takes no credential; the collector holds the token.

Traces: each line of traces.jsonl is one OTLP JSON ExportTraceServiceRequest.
Every attribute not on an allowlist is dropped: on the resource, only
service.name, service.version and forge_perf.run_id survive, and
forge_perf.box, forge_perf.instance_type and forge_perf.series are added; on
spans, span events and links, only the keys in --span-attributes, with scalar
values that hold no "://". Status messages, trace state, scope attributes and
schema URLs are dropped too. Span names, kinds, status codes, timing, trace and
span IDs and links stay. The scrubbed spans go out in requests of at most
--max-request-bytes each.

Metrics: one ExportMetricsServiceRequest of gauges at the run's finish, with
values from the record, so they match the page. A record without drill
results sends none. The metrics go before the spans, and the spans stop at
the deadline.

Nothing here changes the run: every failure is counted and reported in one
line, never raised. Messages name a status code or an error class, never a
response body or a header. A redirect counts as a failure and is not
followed. Exit status: 0 everything was sent, or there was
nothing to send; 1 a request failed or was not sent before the deadline; 2 a
usage error or unusable configuration, with nothing sent.
"""

import argparse
import calendar
import http.client
import json
import math
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RESOURCE_KEEP = ("service.name", "service.version", "forge_perf.run_id")
LOCAL_HOSTS = ("127.0.0.1", "localhost", "::1")
PER_REQUEST_TIMEOUT_S = 20
COMPACT = (",", ":")
INT_STRING = re.compile(r"-?[0-9]{1,20}")
DOUBLE_WORDS = ("NaN", "Infinity", "-Infinity")

GAUGES = (
    ("forge_perf_ingest_p5_bytes_per_second", "ingest_p5_bytes_per_s"),
    ("forge_perf_ingest_median_bytes_per_second", "ingest_median_bytes_per_s"),
    ("forge_perf_writes_per_second", "writes_median_per_s"),
    ("forge_perf_sustained_windows", "sustained_windows"),
    ("forge_perf_bytes_ingested", "bytes_ingested"),
    ("forge_perf_read_back_p5_bytes_per_second", "cache_served.read_back_p5_bytes_per_s"),
    ("forge_perf_read_back_median_bytes_per_second", "cache_served.read_back_median_bytes_per_s"),
    ("forge_perf_restore_p5_bytes_per_second", "cache_served.restore_p5_bytes_per_s"),
    ("forge_perf_restore_median_bytes_per_second", "cache_served.restore_median_bytes_per_s"),
    ("forge_perf_restore_ranged_gets_per_second", "cache_served.restore_ranged_gets_median_per_s"),
)


def log(msg):
    print(f"grafana: {msg}", file=sys.stderr)


def string_attr(key, value):
    return {"key": key, "value": {"stringValue": value}}


# --- scrubbing ------------------------------------------------------------------


def load_allowlist(path):
    keys = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                keys.add(line)
    return keys


def safe_value(value):
    """The value when it is one scalar that holds no URL, else None."""
    if not isinstance(value, dict) or len(value) != 1:
        return None
    kind, v = next(iter(value.items()))
    if kind == "stringValue":
        ok = isinstance(v, str) and "://" not in v
    elif kind == "boolValue":
        ok = isinstance(v, bool)
    elif kind == "intValue":  # OTLP JSON writes an int64 as a decimal string
        ok = (isinstance(v, int) and not isinstance(v, bool)) or (
            isinstance(v, str) and INT_STRING.fullmatch(v) is not None)
    elif kind == "doubleValue":
        ok = (isinstance(v, float) and math.isfinite(v)) or (isinstance(v, int) and not isinstance(v, bool)) \
            or v in DOUBLE_WORDS
    else:
        ok = False
    return value if ok else None


def items(value):
    """VALUE when it is a list, else an empty one: a field of the wrong shape
    reads as absent."""
    return value if isinstance(value, list) else []


def mapping(value):
    return value if isinstance(value, dict) else {}


def scrub_attributes(attrs, allow):
    out = []
    for a in items(attrs):
        if not isinstance(a, dict) or not isinstance(a.get("key"), str) or a["key"] not in allow:
            continue
        v = safe_value(a.get("value"))
        if v is not None:
            out.append({"key": a["key"], "value": v})
    return out


def copy_fields(src, names):
    return {n: src[n] for n in names if n in src}


def scrub_span(span, allow):
    s = copy_fields(span, ("traceId", "spanId", "parentSpanId", "flags", "name", "kind",
                           "startTimeUnixNano", "endTimeUnixNano", "droppedAttributesCount",
                           "droppedEventsCount", "droppedLinksCount"))
    s["attributes"] = scrub_attributes(span.get("attributes"), allow)
    events = []
    for e in items(span.get("events")):
        if not isinstance(e, dict):
            continue
        ev = copy_fields(e, ("timeUnixNano", "name", "droppedAttributesCount"))
        ev["attributes"] = scrub_attributes(e.get("attributes"), allow)
        events.append(ev)
    if events:
        s["events"] = events
    links = []
    for link in items(span.get("links")):
        if not isinstance(link, dict):
            continue
        ln = copy_fields(link, ("traceId", "spanId", "flags", "droppedAttributesCount"))
        ln["attributes"] = scrub_attributes(link.get("attributes"), allow)
        links.append(ln)
    if links:
        s["links"] = links
    code = mapping(span.get("status")).get("code")
    s["status"] = {"code": code} if isinstance(code, (int, str)) and not isinstance(code, bool) else {}
    return s


def scrub_resource(resource, added):
    kept = [a for a in items(mapping(resource).get("attributes"))
            if isinstance(a, dict) and isinstance(a.get("key"), str) and a["key"] in RESOURCE_KEEP and a.get("key") not in added
            and safe_value(a.get("value")) is not None]
    return {"attributes": kept + [string_attr(k, v) for k, v in added.items()]}


def scrubbed_groups(path, allow, added, stats):
    """(resource, scope, spans) per scope, in file order. A line that does not
    parse, or holds a shape the scrub cannot read, is counted and skipped whole."""
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.strip():
                continue
            try:
                groups = scrub_line(json.loads(line), allow, added)
            except (ValueError, KeyError, TypeError, AttributeError, RecursionError):
                stats["unreadable_lines"] += 1
                continue
            yield from groups


def scrub_line(req, allow, added):
    resource_spans = req["resourceSpans"]
    if not isinstance(resource_spans, list):
        raise TypeError
    out = []
    for rs in resource_spans:
        if not isinstance(rs, dict):
            continue
        resource = scrub_resource(rs.get("resource"), added)
        for ss in items(rs.get("scopeSpans")):
            if not isinstance(ss, dict):
                continue
            scope = copy_fields(mapping(ss.get("scope")), ("name", "version"))
            spans = [scrub_span(sp, allow) for sp in items(ss.get("spans")) if isinstance(sp, dict)]
            if spans:
                out.append((resource, scope, spans))
    return out


def dump(obj):
    return json.dumps(obj, separators=COMPACT).encode()


def batches(groups, limit, stats):
    """ExportTraceServiceRequest bodies of at most `limit` bytes each.

    The size of a request is its skeleton plus each span, each scope and each
    resource it holds, plus a separator per element; the sum is an upper bound
    of the serialized size, which the final check confirms.
    """
    skeleton = len(dump({"resourceSpans": []}))
    body, size, last_resource, last_scope = [], skeleton, None, None

    def flush():
        nonlocal body, size, last_resource, last_scope
        if body:
            data = dump({"resourceSpans": body})
            if len(data) <= limit:
                yield data
            else:  # the bound is exact up to separators; never expected
                stats["spans_too_large"] += sum(len(ss["spans"]) for rs in body for ss in rs["scopeSpans"])
        body, size, last_resource, last_scope = [], skeleton, None, None

    for resource, scope, spans in groups:
        r_cost = len(dump({"resource": resource, "scopeSpans": []})) + 1
        s_cost = len(dump({"scope": scope, "spans": []})) + 1
        for span in spans:
            cost = len(dump(span)) + 1
            if skeleton + r_cost + s_cost + cost > limit:
                stats["spans_too_large"] += 1
                continue
            new_resource = last_resource is not resource
            new_scope = new_resource or last_scope is not scope
            extra = cost + (r_cost if new_resource else 0) + (s_cost if new_scope else 0)
            if size + extra > limit:
                yield from flush()
                new_resource = new_scope = True
                extra = cost + r_cost + s_cost
            if new_resource:
                body.append({"resource": resource, "scopeSpans": []})
                last_resource = resource
            if new_scope:
                body[-1]["scopeSpans"].append({"scope": scope, "spans": []})
                last_scope = scope
            body[-1]["scopeSpans"][-1]["spans"].append(span)
            size += extra
            stats["spans"] += 1
    yield from flush()


# --- metrics --------------------------------------------------------------------


def unix_nanos(ts):
    return str(calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")) * 10**9)


def metrics_body(record):
    """The run's gauges as an ExportMetricsServiceRequest, or None."""
    drill = record.get("drill") or {}
    results = drill.get("results")
    if not results:
        return None
    settings = drill.get("settings") or {}
    box = record["box"]
    outcome = record["outcome"]
    labels = {
        "box": box["id"], "instance_type": box["instance_type"], "tier": box.get("tier"),
        "series": record["series"], "class": outcome["class"],
        "traced": "true" if record.get("trace") or "traced" in outcome.get("flags", []) else "false",
        "workers": settings.get("workers"), "size_bytes": settings.get("stop_ingest_at_bytes"),
        # 0 is no budget, as ingot reads it; a record from before the field ran without one.
        "local_blob_max_bytes": record.get("ingot_local_blob_max_bytes") or 0,
        "run_id": record["run_id"],
    }
    attributes = [string_attr(k, str(v)) for k, v in labels.items() if v is not None]
    at = unix_nanos(record["time"]["run_finished_at"])
    metrics = []
    for name, path in GAUGES:
        value = results
        for key in path.split("."):
            value = value.get(key) if isinstance(value, dict) else None
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            continue
        metrics.append({"name": name, "gauge": {"dataPoints": [
            {"attributes": attributes, "timeUnixNano": at, "asDouble": float(value)}]}})
    if not metrics:
        return None
    return dump({"resourceMetrics": [{
        "resource": {"attributes": [string_attr("service.name", "forge-perf")]},
        "scopeMetrics": [{"scope": {"name": "forge-perf"}, "metrics": metrics}]}]})


# --- sending --------------------------------------------------------------------


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuses every redirect, so the data goes only to the configured
    endpoint; urlopen then raises HTTPError with the 3xx code."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


class Sender:
    def __init__(self, endpoint, deadline):
        self.endpoint = endpoint.rstrip("/")
        self.deadline = deadline
        self.late = False

    def post(self, path, data):
        """True when the endpoint answered 2xx. Never raises."""
        left = self.deadline - time.monotonic()
        if left <= 1:
            if not self.late:
                log(f"the deadline passed; {path} and what follows are not sent")
                self.late = True
            return False
        req = urllib.request.Request(self.endpoint + path, data=data, method="POST", headers={
            "Content-Type": "application/json"})
        try:
            with OPENER.open(req, timeout=min(PER_REQUEST_TIMEOUT_S, left)) as resp:
                resp.read()
                return 200 <= resp.status < 300
        except urllib.error.HTTPError as e:
            log(f"{path} answered {e.code}")
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as e:
            log(f"{path} failed ({type(getattr(e, 'reason', e)).__name__})")
        return False


def endpoint_ok(url):
    try:
        u = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    return u.scheme == "http" and u.hostname in LOCAL_HOSTS


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--endpoint", required=True)
    p.add_argument("--runner", required=True)
    p.add_argument("--record")
    p.add_argument("--traces")
    p.add_argument("--span-attributes", required=True)
    p.add_argument("--max-request-bytes", type=int, default=4_000_000)
    p.add_argument("--deadline", type=float, default=110)
    args = p.parse_args(argv)
    deadline = time.monotonic() + args.deadline

    if not endpoint_ok(args.endpoint):
        log("the endpoint must be http:// on this machine; nothing sent")
        return 2
    try:
        runner = json.load(open(args.runner, encoding="utf-8"))
        added = {"forge_perf.run_id": runner["run_id"], "forge_perf.box": runner["box"]["id"],
                 "forge_perf.instance_type": runner["box"]["instance_type"],
                 "forge_perf.series": runner["series"]}
        if not all(isinstance(v, str) and v for v in added.values()):
            raise TypeError
        record = json.load(open(args.record, encoding="utf-8")) if args.record else None
        allow = load_allowlist(args.span_attributes)
    except (OSError, ValueError, KeyError, TypeError) as e:
        log(f"cannot read the runner, the record or the allowlist ({type(e).__name__}); nothing sent")
        return 2

    sender = Sender(args.endpoint, deadline)
    failed = 0
    parts = []

    # The results go first: one small request that every run owes, which a
    # slow or large trace upload must not crowd out of the budget.
    body = None
    if record is not None:
        try:
            body = metrics_body(record)
        except (KeyError, TypeError, ValueError, AttributeError) as e:
            log(f"cannot read the record's results ({type(e).__name__})")
            failed += 1
    if body is None:
        parts.append("no results to send")
    elif sender.post("/v1/metrics", body):
        parts.append("results sent")
    else:
        parts.append("results not sent")
        failed += 1

    if runner.get("trace") and args.traces:
        stats = {"spans": 0, "unreadable_lines": 0, "spans_too_large": 0}
        sent = tried = 0
        try:
            for data in batches(scrubbed_groups(args.traces, allow, added, stats), args.max_request_bytes, stats):
                tried += 1
                if sender.post("/v1/traces", data):
                    sent += 1
                elif sender.late:
                    break  # the rest of the file is neither read nor sent
        except OSError as e:
            log(f"cannot read the traces ({type(e).__name__})")
            tried += 1
        failed += tried - sent
        parts.append(f"traces {sent} of {tried} requests sent"
                     + (", stopped at the deadline" if sender.late else "")
                     + f", {stats['spans']} spans, {stats['unreadable_lines']} unreadable lines, "
                     f"{stats['spans_too_large']} spans too large")
        failed += stats["spans_too_large"] > 0

    log("to the collector: " + "; ".join(parts))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
