"""A stub OTLP/HTTP endpoint for the host tests, on 127.0.0.1 only.

    python3 grafana-stub.py OUT_DIR PORT_FILE

Each POST becomes OUT_DIR/<n>.json holding its path, Authorization header
and body, and the chosen port is written to PORT_FILE once the server
listens. GRAFANA_STATUS is the answer (default 200); GRAFANA_HANG makes it
sleep a minute before answering.
"""

import http.server
import json
import os
import sys
import time

out, port_file = sys.argv[1], sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if os.environ.get("GRAFANA_HANG"):
            time.sleep(60)
        os.makedirs(out, exist_ok=True)  # the tests remove it between cases
        n = len(os.listdir(out))
        with open(os.path.join(out, f"{n:03d}.json"), "w", encoding="utf-8") as f:
            json.dump({"path": self.path, "auth": self.headers.get("Authorization"), "body": body.decode()}, f)
        self.send_response(int(os.environ.get("GRAFANA_STATUS", "200")))
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
with open(port_file + ".tmp", "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
