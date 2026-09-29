#!/usr/bin/env python3
"""Summarizes a run's traces, the collector's traces.jsonl (docs/operations.md,
"Reading a run's traces").

    scripts/operator/trace-summary.py DIR/traces/traces.jsonl [--bucket SECONDS] [--top N]

Each line of the file is one OTLP JSON ExportTraceServiceRequest:
resourceSpans[].scopeSpans[].spans[], with service.name on the resource and
startTimeUnixNano and endTimeUnixNano as decimal strings. A line that does not
parse, such as the last line of a file the collector did not close, is counted
and skipped.

The first table has one row per service.name and span name: count, p50, p95,
p99 and total duration. Waits come first: ingot's bucket.lock and database
pool acquisition (otelpgx's pool.acquire). The rest follow by total time. Then
each wait and each of the --top spans with the most total time (default 5) gets
a table per --bucket seconds (default 10) from the first span's start, by the
start of each span, so a stage whose durations grow after the first 30 seconds
shows up in its later rows.
"""

import argparse
import json
import re
import sys
from pathlib import Path

NS_PER_S = 1_000_000_000
# Waits for a lock or a connection, listed before everything else: the ones
# most likely to be the step that runs one at a time.
POOL_ACQUIRE = re.compile(r"(^|[._ ])acquire$", re.IGNORECASE)


def is_wait(name):
    return name == "bucket.lock" or bool(POOL_ACQUIRE.search(name))


def attribute(attributes, key):
    """The string value of one OTLP JSON attribute, or None."""
    for kv in attributes or ():
        if kv.get("key") == key:
            value = kv.get("value") or {}
            for kind in ("stringValue", "intValue", "doubleValue", "boolValue"):
                if kind in value:
                    return str(value[kind])
    return None


class Traces:
    def __init__(self):
        self.spans = []  # (service, name, start_ns, duration_ns)
        self.trace_ids = set()
        self.lines = 0
        self.bad_lines = 0
        self.bad_spans = 0

    def add_line(self, line):
        self.lines += 1
        try:
            request = json.loads(line)
            spans = []
            for resource_spans in request.get("resourceSpans") or ():
                resource = resource_spans.get("resource") or {}
                service = attribute(resource.get("attributes"), "service.name") or "unknown"
                for scope_spans in resource_spans.get("scopeSpans") or ():
                    for span in scope_spans.get("spans") or ():
                        spans.append((service, span))
        except (ValueError, AttributeError, TypeError):
            self.bad_lines += 1
            return
        for service, span in spans:
            try:
                start = int(span["startTimeUnixNano"])
                end = int(span["endTimeUnixNano"])
                name = span["name"]
            except (KeyError, TypeError, ValueError):
                self.bad_spans += 1
                continue
            self.spans.append((service, name, start, max(0, end - start)))
            if span.get("traceId"):
                self.trace_ids.add(span["traceId"])


def read(path):
    traces = Traces()
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.strip():
                traces.add_line(line)
    return traces


def percentile(ordered, q):
    """Nearest-rank percentile of an ascending list."""
    rank = max(1, -(-len(ordered) * q // 100))
    return ordered[int(rank) - 1]


def duration(ns):
    if ns < 1_000_000:
        return f"{ns / 1000:.0f}us"
    if ns < NS_PER_S:
        return f"{ns / 1_000_000:.1f}ms"
    return f"{ns / NS_PER_S:.2f}s"


def table(header, rows, left=2):
    widths = [max(len(str(r[i])) for r in [header, *rows]) for i in range(len(header))]
    out = []
    for row in [header, *rows]:
        cells = [str(c).ljust(w) if i < left else str(c).rjust(w) for i, (c, w) in enumerate(zip(row, widths))]
        out.append("  ".join(cells).rstrip())
    return "\n".join(out)


def summarize(traces, bucket_s=10, top=5):
    if not traces.spans:
        lines = [f"{traces.lines} lines, {traces.bad_lines} unreadable, no spans"]
        return "\n".join(lines) + "\n"
    first = min(s[2] for s in traces.spans)
    last = max(s[2] + s[3] for s in traces.spans)
    groups = {}
    for service, name, start, dur in traces.spans:
        groups.setdefault((service, name), []).append((start, dur))
    totals = {key: sum(d for _, d in spans) for key, spans in groups.items()}
    order = sorted(groups, key=lambda k: (not is_wait(k[1]), -totals[k], k))

    out = [
        f"{len(traces.spans)} spans in {len(traces.trace_ids)} traces over {duration(last - first)}; "
        f"{traces.lines} lines, {traces.bad_lines} unreadable; {traces.bad_spans} spans skipped for a missing time",
        "",
    ]
    rows = []
    for key in order:
        ds = sorted(d for _, d in groups[key])
        rows.append([key[0], key[1], len(ds), duration(percentile(ds, 50)), duration(percentile(ds, 95)),
                     duration(percentile(ds, 99)), duration(totals[key])])
    out.append(table(["service", "span", "count", "p50", "p95", "p99", "total"], rows))

    waits = [k for k in order if is_wait(k[1])]
    busiest = [k for k in sorted(groups, key=lambda k: (-totals[k], k)) if not is_wait(k[1])][:top]
    for key in waits + busiest:
        buckets = {}
        for start, dur in groups[key]:
            buckets.setdefault((start - first) // (bucket_s * NS_PER_S), []).append(dur)
        rows = []
        for b in sorted(buckets):
            ds = sorted(buckets[b])
            rows.append([f"{b * bucket_s}s", len(ds), duration(percentile(ds, 50)),
                         duration(percentile(ds, 95)), duration(ds[-1]), duration(sum(ds))])
        out += ["", f"{key[0]} {key[1]}, by {bucket_s}-second bucket of span start"]
        out.append(table(["from", "count", "p50", "p95", "max", "total"], rows, left=1))
    return "\n".join(out) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("file", type=Path, help="traces.jsonl from a run's raw tarball")
    parser.add_argument("--bucket", type=int, default=10, help="seconds per time bucket (default 10)")
    parser.add_argument("--top", type=int, default=5, help="spans by total time to bucket (default 5)")
    args = parser.parse_args(argv)
    if args.bucket < 1 or args.top < 0:
        parser.error("--bucket takes 1 or more, --top 0 or more")
    try:
        traces = read(args.file)
    except OSError as e:
        print(f"ERROR: cannot read {args.file}: {e.strerror}", file=sys.stderr)
        return 1
    sys.stdout.write(summarize(traces, args.bucket, args.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
