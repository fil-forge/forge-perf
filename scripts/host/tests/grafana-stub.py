"""A stub of the Grafana step's collector for the host tests, on 127.0.0.1 only.

    python3 grafana-stub.py OUT_DIR OTLP_PORT METRICS_PORT

Each POST to OTLP_PORT becomes OUT_DIR/<n>.json holding its path,
Authorization header and body. GRAFANA_STATUS is the answer (default 200);
GRAFANA_HANG makes it sleep a minute before answering. A GET there answers
405, as the collector's receiver does. METRICS_PORT serves /metrics: the spans
and points of each 2xx request count as accepted, and GRAFANA_EXPORT decides
what became of them: sent (the default), failed ("fail"), or still in the
queue ("stuck").
"""

import http.server
import json
import os
import sys
import threading
import time

out, otlp_port, metrics_port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
accepted = {"spans": 0, "points": 0}
lock = threading.Lock()


def count(path, body):
    """Spans or data points in an OTLP JSON request."""
    try:
        req = json.loads(body)
    except ValueError:
        return None, 0
    if path.endswith("/v1/traces"):
        return "spans", sum(len(ss.get("spans", [])) for rs in req.get("resourceSpans", [])
                            for ss in rs.get("scopeSpans", []))
    if path.endswith("/v1/metrics"):
        return "points", sum(len(m.get("gauge", {}).get("dataPoints", [])) for rm in req.get("resourceMetrics", [])
                             for sm in rm.get("scopeMetrics", []) for m in sm.get("metrics", []))
    return None, 0


class Receiver(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if os.environ.get("GRAFANA_HANG"):
            time.sleep(60)
        status = int(os.environ.get("GRAFANA_STATUS", "200"))
        with lock:
            os.makedirs(out, exist_ok=True)  # the tests remove it between cases
            n = len(os.listdir(out))
            with open(os.path.join(out, f"{n:03d}.json"), "w", encoding="utf-8") as f:
                json.dump({"path": self.path, "auth": self.headers.get("Authorization"), "body": body.decode()}, f)
            kind, k = count(self.path, body)
            if kind and 200 <= status < 300:
                accepted[kind] += k
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self.send_response(405)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


class Metrics(Receiver):
    def do_GET(self):
        mode = os.environ.get("GRAFANA_EXPORT", "")
        with lock:
            a = dict(accepted)
        done = {k: (0 if mode == "stuck" else v) for k, v in a.items()}
        sent = {k: (0 if mode == "fail" else v) for k, v in done.items()}
        failed = {k: done[k] - sent[k] for k in done}
        lines = [
            "# HELP otelcol_receiver_accepted_spans Number of spans successfully pushed into the pipeline.",
            f'otelcol_receiver_accepted_spans{{receiver="otlp",transport="http"}} {a["spans"]}',
            f'otelcol_receiver_accepted_metric_points{{receiver="otlp",transport="http"}} {a["points"]}',
            f'otelcol_exporter_sent_spans{{exporter="otlp_grpc/tempo"}} {sent["spans"]}',
            f'otelcol_exporter_send_failed_spans{{exporter="otlp_grpc/tempo"}} {failed["spans"]}',
            f'otelcol_exporter_sent_metric_points{{exporter="prometheus_remote_write"}} {sent["points"]}',
            f'otelcol_exporter_send_failed_metric_points{{exporter="prometheus_remote_write"}} {failed["points"]}',
            f'otelcol_exporter_queue_size{{data_type="traces",exporter="otlp_grpc/tempo"}} {1 if mode == "stuck" else 0}',
            'otelcol_exporter_queue_size{data_type="metrics",exporter="prometheus_remote_write"} 0',
        ]
        data = ("\n".join(lines) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


servers = [http.server.ThreadingHTTPServer(("127.0.0.1", otlp_port), Receiver),
           http.server.ThreadingHTTPServer(("127.0.0.1", metrics_port), Metrics)]
for s in servers:
    s.daemon_threads = True
threading.Thread(target=servers[1].serve_forever, daemon=True).start()
servers[0].serve_forever()
