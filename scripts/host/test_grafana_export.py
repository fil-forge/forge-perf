"""Tests of grafana-export.py against a stub OTLP/HTTP server on 127.0.0.1.

    cd scripts/host && python3 -m unittest -v test_grafana_export

The traces are built here with a value in every place a traced run can leak
one: bucket names, object keys, URLs, SQL text, peer addresses, a status
message, an exception event and a link attribute. No test reaches a real
endpoint.
"""

import base64
import copy
import http.server
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SCRIPT = HERE / "grafana-export.py"
ALLOWLIST = ROOT / "config" / "grafana-span-attributes.txt"
FIXTURES = HERE / "fixtures"
CREDENTIAL = "123456:glc_fake-grafana-token-value"

# Strings that must not survive the scrub.
LEAKS = ("forge-perf-piri-main-1-piri-0-allocations", "objects/secret-object-key", "://",
         "SELECT id FROM secret_table", "172.30.0.19", "host.docker.internal", "fake-host-name",
         "status message with objects/secret-object-key", "exception message", "linked-bucket",
         "bafyreisecrettask", "did:key:z6Mksecretspace", "vendor=secret-state", "schemas/1.26.0",
         "scope-attr-value", "instance-id-value")


def attr(key, **value):
    return {"key": key, "value": value}


def span(i, trace_id="0af7651916cd43dd8448eb211c80319c", name="objectstore.put"):
    return {
        "traceId": trace_id, "spanId": f"{i:016x}", "parentSpanId": "b7ad6b7169203331",
        "traceState": "vendor=secret-state", "flags": 257, "name": name, "kind": 3,
        "startTimeUnixNano": "1790856295000000000", "endTimeUnixNano": "1790856295009000000",
        "attributes": [
            attr("http.request.method", stringValue="PUT"),
            attr("http.response.status_code", intValue="200"),
            attr("http.route", stringValue="/pdp/piece/upload/:uploadUUID"),
            attr("db.operation.name", stringValue="SELECT"),
            attr("db.system.name", stringValue="postgresql"),
            attr("objectstore.name", stringValue="allocations"),
            attr("objectstore.size", intValue="184"),
            attr("ucan.receipt.ok", boolValue=True),
            attr("url.full", stringValue="http://host.docker.internal:9000/forge-perf-piri-main-1-piri-0-allocations/x"),
            attr("aws.s3.bucket", stringValue="forge-perf-piri-main-1-piri-0-allocations"),
            attr("aws.s3.key", stringValue="objects/secret-object-key"),
            attr("db.query.text", stringValue="SELECT id FROM secret_table"),
            attr("server.address", stringValue="host.docker.internal"),
            attr("network.peer.address", stringValue="172.30.0.19"),
            attr("ucan.task", stringValue="bafyreisecrettask"),
            attr("space.did", stringValue="did:key:z6Mksecretspace"),
            # A listed key whose value is a URL, or not a scalar, is dropped too.
            attr("http.route", stringValue="http://host.docker.internal/x"),
            attr("error.type", arrayValue={"values": [{"stringValue": "objects/secret-object-key"}]}),
        ],
        "events": [{"timeUnixNano": "1790856295001000000", "name": "exception", "attributes": [
            attr("exception.type", stringValue="*errors.errorString"),
            attr("exception.message", stringValue="exception message objects/secret-object-key")]}],
        "links": [{"traceId": "4bf92f3577b34da6a3ce929d0e0e4736", "spanId": "53995c3f42cd8ad8",
                   "traceState": "vendor=secret-state",
                   "attributes": [attr("aws.s3.bucket", stringValue="linked-bucket"),
                                  attr("rpc.method", stringValue="S3/PutObject")]}],
        "status": {"code": 2, "message": "status message with objects/secret-object-key"},
    }


def request(service, spans, run_id="main-20261001t120000z"):
    return {"resourceSpans": [{
        "resource": {"attributes": [
            attr("service.name", stringValue=service), attr("service.version", stringValue="v1.2.3"),
            attr("forge_perf.run_id", stringValue=run_id), attr("host.name", stringValue="fake-host-name"),
            attr("service.instance.id", stringValue="instance-id-value")]},
        "schemaUrl": "https://opentelemetry.io/schemas/1.26.0",
        "scopeSpans": [{"scope": {"name": "github.com/fil-forge/piri/pkg/store/objectstore", "version": "0.1",
                                  "attributes": [attr("x", stringValue="scope-attr-value")]},
                        "schemaUrl": "https://opentelemetry.io/schemas/1.26.0",
                        "spans": spans}]}]}


class Stub:
    """An OTLP/HTTP endpoint that records each request and answers `status`.
    `delay` maps a path suffix to seconds to wait before answering, `location`
    goes out with a 3xx status, and `garbage` answers a line that is not HTTP."""

    def __init__(self, status=200):
        self.requests = []
        self.status = status
        self.delay = {}
        self.location = None
        self.garbage = False
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                stub.requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
                for suffix, seconds in stub.delay.items():
                    if self.path.endswith(suffix):
                        time.sleep(seconds)
                if stub.garbage:
                    self.wfile.write(b"GARBAGE response-text\r\n\r\n")
                    return
                self.send_response(stub.status)
                if stub.location:
                    self.send_header("Location", stub.location)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

            do_GET = do_POST

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/otlp"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def bodies(self, path):
        return [json.loads(r["body"]) for r in self.requests if r["path"] == path]


class ExportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.stub = Stub()
        self.creds = self.dir / "grafana-otlp"
        self.creds.write_text(CREDENTIAL + "\n")
        self.record = json.loads((FIXTURES / "traced" / "expected.json").read_text())
        self.runner = json.loads((FIXTURES / "traced" / "runner.json").read_text())

    def tearDown(self):
        self.stub.close()
        self.tmp.cleanup()

    def write(self, name, obj):
        path = self.dir / name
        path.write_text(json.dumps(obj))
        return path

    def traces(self, lines):
        path = self.dir / "traces.jsonl"
        path.write_text("".join(json.dumps(line) + "\n" for line in lines))
        return path

    def export(self, *extra, record=True, traces=None, endpoint=None, runner=None):
        args = ["--endpoint", endpoint or self.stub.url, "--credentials", str(self.creds),
                "--runner", str(self.write("runner.json", runner or self.runner)),
                "--span-attributes", str(ALLOWLIST), "--deadline", "20"]
        if record:
            args += ["--record", str(self.write("record.json", self.record))]
        if traces:
            args += ["--traces", str(traces)]
        proc = subprocess.run([sys.executable, str(SCRIPT), *args, *extra],
                              capture_output=True, text=True, timeout=60, check=False)
        self.assertNotIn(CREDENTIAL.split(":")[1], proc.stdout + proc.stderr)
        self.assertNotIn(base64.b64encode(CREDENTIAL.encode()).decode(), proc.stdout + proc.stderr)
        return proc

    def test_scrub_keeps_the_allowlist_and_drops_everything_else(self):
        proc = self.export(traces=self.traces([request("piri", [span(1), span(2)]),
                                               request("ingot", [span(3, name="bucket.lock")])]))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        raw = b"".join(r["body"] for r in self.stub.requests if r["path"] == "/otlp/v1/traces")
        for leak in LEAKS:
            self.assertNotIn(leak.encode(), raw, leak)
        (body,) = self.stub.bodies("/otlp/v1/traces")
        rs = body["resourceSpans"]
        self.assertEqual([r["resource"]["attributes"] for r in rs][0], [
            attr("service.name", stringValue="piri"), attr("service.version", stringValue="v1.2.3"),
            attr("forge_perf.run_id", stringValue="main-20261001t120000z"),
            attr("forge_perf.box", stringValue="main"), attr("forge_perf.instance_type", stringValue="m9gd.2xlarge"),
            attr("forge_perf.series", stringValue="per-trigger")])
        ss = rs[0]["scopeSpans"][0]
        self.assertEqual(ss["scope"], {"name": "github.com/fil-forge/piri/pkg/store/objectstore", "version": "0.1"})
        s = ss["spans"][0]
        self.assertEqual({a["key"]: a["value"] for a in s["attributes"]}, {
            "http.request.method": {"stringValue": "PUT"}, "http.response.status_code": {"intValue": "200"},
            "http.route": {"stringValue": "/pdp/piece/upload/:uploadUUID"},
            "db.operation.name": {"stringValue": "SELECT"}, "db.system.name": {"stringValue": "postgresql"},
            "objectstore.name": {"stringValue": "allocations"}, "objectstore.size": {"intValue": "184"},
            "ucan.receipt.ok": {"boolValue": True}})
        self.assertEqual((s["traceId"], s["spanId"], s["parentSpanId"], s["flags"], s["name"], s["kind"],
                          s["startTimeUnixNano"], s["endTimeUnixNano"], s["status"]),
                         ("0af7651916cd43dd8448eb211c80319c", "0000000000000001", "b7ad6b7169203331", 257,
                          "objectstore.put", 3, "1790856295000000000", "1790856295009000000", {"code": 2}))
        self.assertEqual(s["events"], [{"timeUnixNano": "1790856295001000000", "name": "exception",
                                        "attributes": [attr("exception.type", stringValue="*errors.errorString")]}])
        self.assertEqual(s["links"], [{"traceId": "4bf92f3577b34da6a3ce929d0e0e4736", "spanId": "53995c3f42cd8ad8",
                                       "attributes": [attr("rpc.method", stringValue="S3/PutObject")]}])
        self.assertEqual([r["resource"]["attributes"][0]["value"]["stringValue"] for r in rs], ["piri", "ingot"])
        self.assertEqual(rs[1]["scopeSpans"][0]["spans"][0]["name"], "bucket.lock")
        self.assertIn("traces 1 of 1 requests sent, 3 spans, 0 unreadable lines", proc.stderr)

    def test_basic_auth_and_content_type(self):
        self.export(traces=self.traces([request("piri", [span(1)])]))
        self.assertEqual([r["path"] for r in self.stub.requests], ["/otlp/v1/metrics", "/otlp/v1/traces"])
        want = "Basic " + base64.b64encode(CREDENTIAL.encode()).decode()
        for r in self.stub.requests:
            self.assertEqual(r["headers"]["Authorization"], want)
            self.assertEqual(r["headers"]["Content-Type"], "application/json")

    def test_requests_split_under_the_size_limit(self):
        limit = 6000
        lines = [request("piri", [span(i) for i in range(10)]), request("ingot", [span(100 + i) for i in range(25)])]
        proc = self.export("--max-request-bytes", str(limit), traces=self.traces(lines))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        sent = [r for r in self.stub.requests if r["path"] == "/otlp/v1/traces"]
        self.assertGreater(len(sent), 3)
        self.assertTrue(all(len(r["body"]) <= limit for r in sent), [len(r["body"]) for r in sent])
        ids = [s["spanId"] for b in self.stub.bodies("/otlp/v1/traces") for rs in b["resourceSpans"]
               for ss in rs["scopeSpans"] for s in ss["spans"]]
        self.assertEqual(sorted(ids), sorted([f"{i:016x}" for i in range(10)] + [f"{100 + i:016x}" for i in range(25)]))
        for b in self.stub.bodies("/otlp/v1/traces"):
            for rs in b["resourceSpans"]:
                self.assertEqual(rs["resource"]["attributes"][0]["key"], "service.name")
        self.assertIn(f"traces {len(sent)} of {len(sent)} requests sent, 35 spans", proc.stderr)

    def test_the_default_limit_batches_lines_together(self):
        self.export(traces=self.traces([request("piri", [span(i)]) for i in range(50)]))
        self.assertEqual(len(self.stub.bodies("/otlp/v1/traces")), 1)

    def test_metrics_body(self):
        proc = self.export()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        (body,) = self.stub.bodies("/otlp/v1/metrics")
        rm = body["resourceMetrics"][0]
        self.assertEqual(rm["resource"]["attributes"], [attr("service.name", stringValue="forge-perf")])
        metrics = {m["name"]: m["gauge"]["dataPoints"] for m in rm["scopeMetrics"][0]["metrics"]}
        self.assertEqual({k: v[0]["asDouble"] for k, v in metrics.items()}, {
            "forge_perf_ingest_p5_bytes_per_second": 25360000.0,
            "forge_perf_ingest_median_bytes_per_second": 26090000.0,
            "forge_perf_writes_per_second": 0.2,
            "forge_perf_sustained_windows": 6.0,
            "forge_perf_bytes_ingested": 1073741824.0})
        point = metrics["forge_perf_sustained_windows"][0]
        # 2026-10-01T12:09:30Z, the record's run_finished_at.
        self.assertEqual(point["timeUnixNano"], "1790856570000000000")
        self.assertEqual({a["key"]: a["value"]["stringValue"] for a in point["attributes"]}, {
            "box": "main", "instance_type": "m9gd.2xlarge", "tier": "1", "series": "per-trigger",
            "class": "valid", "traced": "true", "workers": "4", "size_bytes": "1000000000",
            "run_id": "main-20261001t120000z"})
        self.assertIn("results sent", proc.stderr)

    def test_an_untraced_run_sends_its_results_and_no_spans(self):
        self.runner["trace"] = None
        self.record = json.loads((FIXTURES / "valid" / "expected.json").read_text())
        self.export(traces=self.traces([request("piri", [span(1)])]))
        self.assertEqual([r["path"] for r in self.stub.requests], ["/otlp/v1/metrics"])
        (body,) = self.stub.bodies("/otlp/v1/metrics")
        point = body["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["gauge"]["dataPoints"][0]
        self.assertIn(attr("traced", stringValue="false"), point["attributes"])

    def test_a_run_without_p5_sends_what_it_has(self):
        self.record = json.loads((FIXTURES / "wrote-nothing" / "expected.json").read_text())
        results = self.record["drill"]["results"]
        proc = self.export()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        (body,) = self.stub.bodies("/otlp/v1/metrics")
        names = {m["name"] for m in body["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]}
        self.assertNotIn("forge_perf_ingest_p5_bytes_per_second", names)
        self.assertIn("forge_perf_sustained_windows", names)
        self.assertEqual(len(names), sum(isinstance(results[f], (int, float)) for f in (
            "ingest_p5_bytes_per_s", "ingest_median_bytes_per_s", "writes_median_per_s", "sustained_windows",
            "bytes_ingested")))

    def test_a_run_whose_drill_never_ran_sends_no_results(self):
        self.record = json.loads((FIXTURES / "stack-boot-failed" / "expected.json").read_text())
        proc = self.export()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.stub.requests, [])
        self.assertIn("no results to send", proc.stderr)

    def test_an_endpoint_that_fails_is_counted_and_nothing_raises(self):
        self.stub.status = 500
        proc = self.export(traces=self.traces([request("piri", [span(1)])]))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("/v1/traces answered 500", proc.stderr)
        self.assertIn("traces 0 of 1 requests sent", proc.stderr)
        self.assertIn("results not sent", proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)

    def test_an_unreachable_endpoint_is_counted_and_nothing_raises(self):
        self.stub.close()
        proc = self.export(traces=self.traces([request("piri", [span(1)])]))
        self.stub = Stub()  # for tearDown
        self.assertEqual(proc.returncode, 1)
        self.assertIn("results not sent", proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)

    def test_slow_trace_requests_leave_the_results_sent(self):
        self.stub.delay = {"/v1/traces": 4}
        lines = [request("piri", [span(i) for i in range(10)]) for _ in range(20)]
        started = time.monotonic()
        proc = self.export("--max-request-bytes", "12000", "--deadline", "6", traces=self.traces(lines))
        self.assertLess(time.monotonic() - started, 15)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(self.stub.requests[0]["path"], "/otlp/v1/metrics")
        self.assertIn("results sent", proc.stderr)
        self.assertIn("stopped at the deadline", proc.stderr)
        self.assertLess(len(self.stub.bodies("/otlp/v1/traces")), 5)

    def test_a_redirect_is_a_failure_and_is_not_followed(self):
        other = Stub()
        try:
            self.stub.status = 302
            self.stub.location = other.url + "/elsewhere"
            proc = self.export(traces=self.traces([request("piri", [span(1)])]))
            self.assertEqual(other.requests, [])
            self.assertEqual(proc.returncode, 1)
            self.assertIn("/v1/metrics answered 302", proc.stderr)
            self.assertIn("results not sent", proc.stderr)
        finally:
            other.close()

    def test_a_garbage_answer_is_counted_and_its_text_not_printed(self):
        self.stub.garbage = True
        proc = self.export(traces=self.traces([request("piri", [span(1)])]))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("results not sent", proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)
        self.assertNotIn("response-text", proc.stderr)

    def test_odd_shapes_are_skipped_without_a_traceback(self):
        odd = span(2)
        odd["attributes"] = 7
        odd["events"] = [5, {"name": "e", "attributes": "x"}]
        odd["links"] = {"not": "a list"}
        odd["status"] = [2]
        listkey = span(3)
        listkey["attributes"] = [{"key": ["http.route"], "value": {"stringValue": "/x"}}]
        bad_resource = request("piri", [span(4)])
        bad_resource["resourceSpans"][0]["resource"] = {"attributes": [{"key": {"a": 1}, "value": 3}]}
        bad_scope = request("piri", [span(5)])
        bad_scope["resourceSpans"][0]["scopeSpans"][0]["scope"] = "scope"
        bad_scope["resourceSpans"][0]["scopeSpans"].append({"spans": 9})
        proc = self.export(traces=self.traces([request("piri", [span(1)]), request("piri", [odd, listkey]),
                                               bad_resource, bad_scope, {"resourceSpans": [3, {"scopeSpans": 1}]}]))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)
        self.assertIn("results sent", proc.stderr)
        spans = {s["spanId"]: s for b in self.stub.bodies("/otlp/v1/traces") for rs in b["resourceSpans"]
                 for ss in rs["scopeSpans"] for s in ss["spans"]}
        self.assertEqual(sorted(spans), [f"{i:016x}" for i in range(1, 6)])
        self.assertEqual(spans[f"{2:016x}"]["attributes"], [])
        self.assertEqual(spans[f"{3:016x}"]["attributes"], [])
        self.assertEqual(spans[f"{2:016x}"]["events"], [{"name": "e", "attributes": []}])
        self.assertEqual(spans[f"{2:016x}"]["status"], {})

    def test_numbers_and_booleans_must_be_numbers_and_booleans(self):
        s = span(1)
        s["attributes"] = [
            attr("http.response.status_code", intValue="/bucket-x/key-x"),
            attr("ucan.receipt.ok", boolValue="http://x"),
            attr("objectstore.size", doubleValue="SELECT x FROM t"),
            attr("objectstore.size", intValue=True),
            attr("http.response.status_code", intValue="-404"),
            attr("objectstore.size", doubleValue=1.5),
            attr("objectstore.size", doubleValue="NaN"),
            attr("ucan.receipt.ok", boolValue=False),
        ]
        self.export(traces=self.traces([request("piri", [s])]))
        (body,) = self.stub.bodies("/otlp/v1/traces")
        kept = body["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["attributes"]
        self.assertEqual([a["value"] for a in kept], [
            {"intValue": "-404"}, {"doubleValue": 1.5}, {"doubleValue": "NaN"}, {"boolValue": False}])

    def test_unreadable_lines_are_skipped(self):
        path = self.traces([request("piri", [span(1)])])
        with open(path, "a") as f:
            f.write('{"resourceSpans": [{"resource"\n')
        proc = self.export(traces=path)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("1 spans, 1 unreadable lines", proc.stderr)

    def test_a_malformed_credential_sends_nothing(self):
        for bad in ("no-colon", ":token", "123:", "123:tok en"):
            self.creds.write_text(bad)
            proc = self.export(traces=self.traces([request("piri", [span(1)])]))
            self.assertEqual(proc.returncode, 2, bad)
            self.assertNotIn(bad, proc.stderr)
        self.assertEqual(self.stub.requests, [])

    def test_plain_http_goes_only_to_this_machine(self):
        proc = self.export(endpoint="http://otlp.example.com/otlp")
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(self.stub.requests, [])

    def test_a_record_run_id_in_the_resource_follows_the_runner(self):
        runner = copy.deepcopy(self.runner)
        self.export(traces=self.traces([request("piri", [span(1)], run_id="other-run")]), runner=runner)
        (body,) = self.stub.bodies("/otlp/v1/traces")
        attrs = body["resourceSpans"][0]["resource"]["attributes"]
        self.assertEqual([a["value"]["stringValue"] for a in attrs if a["key"] == "forge_perf.run_id"],
                         [runner["run_id"]])


if __name__ == "__main__":
    unittest.main()
