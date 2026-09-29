#!/usr/bin/env bash
# The Grafana step's collector, forge-perf-grafana, for the host tests'
# docker stubs, which hand it every docker command that names it.
#
# `run` writes its arguments to $D/grafana-run.args, one per line, and the
# token mount's mode, trailing newline and SHA-256 to $D/grafana-token.facts
# (never the token), then starts grafana-stub.py on the two published ports.
# GRAFANA_RUN_FAIL: run fails. `stop` and `rm -f` end the stub and append
# themselves to $D/grafana-docker.log. `logs` prints a line, with
# GRAFANA_LOG_ERROR an error line as well, and with GRAFANA_LOG_LEAK the
# mounted token too. GRAFANA_TOKEN_GONE: `logs` removes the token file first.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
echo "$*" >>"$D/grafana-docker.log"

stub_stop() {
  [ -e "$D/grafana-stub.pid" ] || return 0
  kill "$(cat "$D/grafana-stub.pid")" 2>/dev/null || true
  rm -f "$D/grafana-stub.pid"
}

token_file() { sed -n 's|:/secrets/token:ro$||p' "$D/grafana-run.args"; }

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

case "$1" in
  run)
    printf '%s\n' "$@" >"$D/grafana-run.args"
    [ -z "${GRAFANA_RUN_FAIL:-}" ] || { echo "docker: Error response from daemon" >&2; exit 125; }
    port="" mport="" prev=""
    for a; do
      if [ "$prev" = -p ]; then
        case "$a" in
          127.0.0.1:*:4318) port="${a#127.0.0.1:}" port="${port%:4318}" ;;
          127.0.0.1:*:8888) mport="${a#127.0.0.1:}" mport="${mport%:8888}" ;;
        esac
      fi
      prev="$a"
    done
    tok="$(token_file)"
    if [ -n "$tok" ] && [ -f "$tok" ]; then
      mode="$(stat -c %a "$tok" 2>/dev/null || stat -f %Lp "$tok")"
      if [ -n "$(tail -c 1 "$tok")" ]; then nl=no; else nl=yes; fi
      printf 'mode=%s newline=%s sha256=%s\n' "$mode" "$nl" "$(sha256 <"$tok")" \
        >"$D/grafana-token.facts"
    fi
    [ -n "$port" ] && [ -n "$mport" ] || { echo "grafana-docker: no published ports" >&2; exit 125; }
    stub_stop
    python3 "$here/grafana-stub.py" "$D/grafana" "$port" "$mport" </dev/null >/dev/null 2>&1 &
    echo $! >"$D/grafana-stub.pid"
    echo cid-grafana
    ;;
  stop) stub_stop ;;
  logs)
    [ -z "${GRAFANA_TOKEN_GONE:-}" ] || rm -f "$(token_file)"
    echo "collector log"
    [ -z "${GRAFANA_LOG_ERROR:-}" ] || echo "2026-10-01T20:01:00Z error exporterhelper Exporting failed. Dropping data."
    if [ -n "${GRAFANA_LOG_LEAK:-}" ]; then cat "$(token_file)"; fi
    ;;
  rm) stub_stop ;;
  *) echo "grafana-docker: unexpected $*" >&2; exit 1 ;;
esac
