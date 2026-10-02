#!/usr/bin/env bash
# The Grafana step (runlib.sh grafana_export, docs/runner.md "Grafana"): the
# collector it starts, what it mounts and publishes, the skip cases, its
# summary line and its cleanup on every path. docker is stubbed on PATH:
# forge-perf-grafana's `run` starts grafana-stub.py on the published ports
# (grafana-docker.sh), so grafana-export.py, curl and timeout run for real
# against it. aws is stubbed for the token's SSM read. No test reaches Grafana.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2016
set -euo pipefail
# The CI runner starts steps under systemd, where lib.sh refuses skip mode.
unset INVOCATION_ID FORGE_PERF_HOST_OPS FORGE_PERF_LOCK_HELD FORGE_PERF_SECRETS FORGE_PERF_GRAFANA_TOKEN_FILE

host="$(cd "$(dirname "$0")/.." && pwd -P)"
repo="$(cd "$host/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/grafana-step-test.XXXXXX")"
export D="$work/d" TESTS="$host/tests" PYTHONDONTWRITEBYTECODE=1
cleanup() {
  [ ! -e "$D/grafana-stub.pid" ] || kill "$(cat "$D/grafana-stub.pid")" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/bin"

cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *forge-perf-grafana*) exec "$TESTS/grafana-docker.sh" "$@" ;;
  "image inspect"*) exit 0 ;;
  *) echo "docker stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$D/aws.log"
case "$*" in
  *"ssm get-parameter"*grafana-token*) [ -e "$D/ssm-token" ] || exit 254; cat "$D/ssm-token" ;;
  *) echo "aws stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/"*

secret=glc_fake-grafana-token-value
spans="$(jq '[.resourceSpans[].scopeSpans[].spans[]] | length' "$TESTS/grafana-span.json")"
read -r gport gmport < <(python3 -c '
import socket
s = [socket.socket() for _ in range(2)]
for x in s:
    x.bind(("127.0.0.1", 0))
print(*[x.getsockname()[1] for x in s])')

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
has() { grep -qF -- "$2" "$1" || fail "$1 lacks: $2"; }
lacks() { ! grep -qF -- "$2" "$1" || fail "$1 has: $2"; }

# setup: a traced run's directory, the committed configuration and a token
# in SSM.
setup() {
  rm -rf "$D" "$work/checkout" "$work/run" "$work/rt"
  mkdir -p "$D" "$work/checkout/config" "$work/run/traces" "$work/rt"
  ln -s "$repo/scripts" "$work/checkout/scripts"
  cp "$repo/config/"{grafana.conf,otel-grafana.yaml,grafana-span-attributes.txt,images.lock} "$work/checkout/config/"
  cp "$host/fixtures/traced/runner.json" "$work/run/runner.json"
  cp "$host/fixtures/traced/expected.json" "$work/run/record.json"
  cp "$TESTS/grafana-span.json" "$work/run/traces/traces.jsonl"
  echo "$secret" >"$D/ssm-token"
}

# conf NAME=VALUE: set one line of the checkout's grafana.conf.
conf() {
  sed "s|^${1%%=*}=.*|$1|" "$work/checkout/config/grafana.conf" >"$work/grafana.conf"
  mv "$work/grafana.conf" "$work/checkout/config/grafana.conf"
}

# step [VAR=VALUE...]: the step on a box (or in skip mode with
# FORGE_PERF_HOST_OPS=skip), its lines in $work/out.
step_run() {
  (
    for a; do export "${a?}"; done
    PATH="$work/bin:$PATH"
    FORGE_PERF_CHECKOUT="$work/checkout" FORGE_PERF_RUNTIME="$work/rt"
    FORGE_PERF_IMDS_URL=http://127.0.0.1:9
    FORGE_PERF_GRAFANA_PORT="$gport" FORGE_PERF_GRAFANA_METRICS_PORT="$gmport"
    # shellcheck source=../lib.sh
    . "$host/lib.sh"
    # shellcheck source=../runlib.sh
    . "$host/runlib.sh"
    grafana_export "$work/run/runner.json" "$work/run/record.json" "$work/run"
  ) >"$work/out" 2>&1 || fail "grafana_export returned non-zero"
}

requests() { cat "$D"/grafana/*.json 2>/dev/null | jq -r .path | tr '\n' ' '; }
args() { cat "$D/grafana-run.args" 2>/dev/null; }

# Every path leaves no collector, no stub and no token file behind.
cleaned() {
  [ ! -e "$work/rt/secrets/grafana-token" ] || fail "$1: the token file was left"
  [ ! -e "$D/grafana-stub.pid" ] || fail "$1: the collector was left running"
  [ ! -e "$D/grafana-run.args" ] || [ "$(tail -1 "$D/grafana-docker.log")" = "rm -f forge-perf-grafana" ] ||
    fail "$1: the collector was not removed last: $(tail -1 "$D/grafana-docker.log")"
  lacks "$work/out" "$secret"
}

# --- both halves ------------------------------------------------------------------

setup
step_run
[ "$(requests)" = "/v1/metrics /v1/traces " ] || fail "requests: $(requests)"
[ "$(jq -r .auth "$D"/grafana/*.json | sort -u)" = null ] || fail "the collector was sent a credential"
has "$work/out" "grafana: spans $spans sent, 0 failed, 0 unsent; points 10 sent, 0 failed, 0 unsent"
# The collector: its name, the two ports on 127.0.0.1 only, the token file
# read-only, the configuration, the pinned image and the four settings.
image="$(awk '$1 == "OTEL_COLLECTOR_IMAGE" { sub(/:[^:\/]*$/, "", $2); print $2 "@" $3 }' "$repo/config/images.lock")"
[ "$(args | head -4 | tr '\n' ' ')" = "run -d --name forge-perf-grafana " ] || fail "run: $(args | head -4)"
[ "$(args | grep -A1 -x -- -p | grep -vx -- -p | grep -vx -- -- | tr '\n' ' ')" = \
  "127.0.0.1:$gport:4318 127.0.0.1:$gmport:8888 " ] || fail "published: $(args | grep -A1 -x -- -p)"
! args | grep -qE -- '^--(network|net)(=|$)|^--publish|^-P$' || fail "another network setting: $(args)"
[ "$(args | grep -A1 -x -- -v | grep -vx -- -v | grep -vx -- -- | tr '\n' ' ')" = \
  "$work/rt/secrets/grafana-token:/secrets/token:ro $work/checkout/config/otel-grafana.yaml:/etc/forge-perf/otel-grafana.yaml:ro " ] ||
  fail "mounts: $(args | grep -A1 -x -- -v)"
[ "$(args | grep -A1 -x -- -e | grep -vx -- -e | grep -vx -- -- | tr '\n' ' ')" = \
  "GRAFANA_TEMPO_ENDPOINT=tempo-us-central1.grafana.net:443 GRAFANA_TEMPO_USER=233235 GRAFANA_PROM_URL=https://prometheus-prod-10-prod-us-central-0.grafana.net/api/prom/push GRAFANA_PROM_USER=475506 " ] ||
  fail "environment: $(args | grep -A1 -x -- -e)"
[ "$(args | grep -A3 -xF -- "$image" | tr '\n' ' ')" = "$image --config /etc/forge-perf/otel-grafana.yaml " ] ||
  fail "image and command: $(args | grep -A3 -xF -- "$image")"
! args | grep -q -- '--set' || fail "a --set with both halves on"
# The token: SSM's trailing newline gone, mode 600, and nowhere else.
want="$(printf '%s' "$secret" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)"
[ "$(cat "$D/grafana-token.facts")" = "mode=600 newline=no sha256=$want" ] || fail "token file: $(cat "$D/grafana-token.facts")"
! grep -rqF "$secret" "$D/grafana-run.args" "$D/grafana-docker.log" "$D/aws.log" "$work/run" "$D/grafana" ||
  fail "the token reached a file"
has "$D/aws.log" "--name /forge-perf/grafana-token"
[ "$(cat "$work/run/grafana-export.log")" = "collector log" ] || fail "the collector's log was not kept"
has "$D/grafana-docker.log" "stop -t "
cleaned "both halves"
echo "ok: the collector publishes on 127.0.0.1 only, reads the token from a read-only mount, and the step reports and cleans up"

# --- skip cases -------------------------------------------------------------------

setup
rm "$D/ssm-token"
step_run
has "$work/out" "grafana: no token in SSM; nothing sent"
[ ! -e "$D/grafana-run.args" ] || fail "a collector without a token"
cleaned "no token"

setup
: >"$D/ssm-token"
step_run
has "$work/out" "grafana: no token in SSM; nothing sent"
[ ! -e "$D/grafana-run.args" ] || fail "a collector with an empty token"
cleaned "empty token"

setup
step_run FORGE_PERF_HOST_OPS=skip
has "$work/out" "grafana: a local run sends only with FORGE_PERF_GRAFANA_TOKEN_FILE set; nothing sent"
[ ! -e "$D/grafana-run.args" ] || fail "a local collector without a token file"
[ ! -e "$D/aws.log" ] || fail "a local run read SSM"

setup
echo "$secret" >"$work/token"
step_run FORGE_PERF_HOST_OPS=skip FORGE_PERF_GRAFANA_TOKEN_FILE="$work/token"
[ "$(requests)" = "/v1/metrics /v1/traces " ] || fail "local requests: $(requests)"
[ "$(cat "$D/grafana-token.facts")" = "mode=600 newline=no sha256=$want" ] || fail "local token file: $(cat "$D/grafana-token.facts")"
[ -e "$work/token" ] || fail "the step removed the caller's token file"
cleaned "local"
echo "ok: without a token, or on a laptop without FORGE_PERF_GRAFANA_TOKEN_FILE, nothing starts"

# An empty endpoint or user turns its half off: its pipeline goes to nop with
# placeholder settings, and nothing of that kind is sent.
setup
conf GRAFANA_TEMPO_ENDPOINT=
step_run
[ "$(requests)" = "/v1/metrics " ] || fail "Tempo off: $(requests)"
args | grep -qxF -- '--set=service::pipelines::traces::exporters=[nop]' || fail "Tempo off: no nop"
args | grep -qxF -- 'GRAFANA_TEMPO_ENDPOINT=127.0.0.1:9' || fail "Tempo off: no placeholder"
! args | grep -qF -- 'metrics::exporters' || fail "Tempo off: metrics off too"
cleaned "Tempo off"

setup
conf GRAFANA_PROM_USER=
step_run
[ "$(requests)" = "/v1/traces " ] || fail "Prometheus off: $(requests)"
args | grep -qxF -- '--set=service::pipelines::metrics::exporters=[nop]' || fail "Prometheus off: no nop"
args | grep -qxF -- 'GRAFANA_PROM_URL=https://127.0.0.1:9/' || fail "Prometheus off: no placeholder"
cleaned "Prometheus off"

setup
conf GRAFANA_PROM_URL=
conf GRAFANA_TEMPO_USER=
step_run
has "$work/out" "grafana: no Tempo or Prometheus in config/grafana.conf; nothing sent"
[ ! -e "$D/grafana-run.args" ] && [ ! -e "$D/aws.log" ] || fail "both off started something"

setup
conf GRAFANA_TEMPO_USER=tempo
conf GRAFANA_PROM_USER=4755O6
step_run
has "$work/out" "GRAFANA_TEMPO_USER a number; traces off"
has "$work/out" "GRAFANA_PROM_USER a number; results off"
[ ! -e "$D/grafana-run.args" ] || fail "users that are not numbers started a collector"

# Prometheus off and an untraced run: nothing to send.
setup
conf GRAFANA_PROM_URL=
rm "$work/run/traces/traces.jsonl"
step_run
has "$work/out" "grafana: nothing to send"
[ ! -e "$D/grafana-run.args" ] && [ ! -e "$D/aws.log" ] || fail "nothing to send started something"
echo "ok: an empty endpoint or user, or a user that is not a number, turns its half off"

# --- failures ---------------------------------------------------------------------

setup
step_run GRAFANA_RUN_FAIL=1
has "$work/out" "grafana: cannot start the collector; nothing sent"
[ -z "$(requests)" ] || fail "sent without a collector"
cleaned "run fails"

setup
step_run GRAFANA_EXPORT=fail
has "$work/out" "grafana: spans 0 sent, $spans failed, 0 unsent; points 0 sent, 10 failed, 0 unsent"
cleaned "export fails"

setup
step_run GRAFANA_STATUS=500
has "$work/out" "grafana: grafana-export.py exited 1; the run goes on"
has "$work/out" "grafana: spans 0 sent, 0 failed, 0 unsent; points 0 sent, 0 failed, 0 unsent"
cleaned "receiver refuses"

# Queues that never empty: the step stops waiting ten seconds before the end
# of its budget and counts what is left as unsent.
setup
conf GRAFANA_TIMEOUT_S=14
rm "$work/run/traces/traces.jsonl"
start=$SECONDS
step_run GRAFANA_EXPORT=stuck
[ $((SECONDS - start)) -le 20 ] || fail "a stuck queue held the step $((SECONDS - start)) s on a 14 s budget"
has "$work/out" "points 0 sent, 0 failed, 10 unsent"
cleaned "stuck"

# A collector log that holds the token is not kept.
setup
step_run GRAFANA_LOG_LEAK=1
has "$work/out" "grafana: the collector's log holds the token; it is not kept"
[ ! -e "$work/run/grafana-export.log" ] || fail "a log with the token was kept"
[ ! -e "$work/rt/secrets/grafana-export.log" ] || fail "a log with the token was left in secrets"
cleaned "log leak"

# A log that cannot be checked for the token is not kept either.
setup
step_run GRAFANA_TOKEN_GONE=1
has "$work/out" "grafana: cannot check the collector's log for the token; it is not kept"
[ ! -e "$work/run/grafana-export.log" ] || fail "an unchecked log was kept"
[ ! -e "$work/rt/secrets/grafana-export.log" ] || fail "an unchecked log was left in secrets"
cleaned "token gone"

# A kept log's error lines also go to the journal, which outlives the wipe.
setup
step_run GRAFANA_LOG_ERROR=1
has "$work/out" "grafana: collector: 2026-10-01T20:01:00Z error exporterhelper Exporting failed. Dropping data."
has "$work/run/grafana-export.log" "Exporting failed"
cleaned "log error"

# A leftover collector from an earlier step is removed before the start.
setup
step_run
[ "$(head -1 "$D/grafana-docker.log")" = "rm -f forge-perf-grafana" ] || fail "no removal before the start"
echo "ok: a collector that fails, refuses, never drains or logs the token is still stopped, removed and its token deleted"

if [ "$failures" -ne 0 ]; then
  echo "grafana_step_test: $failures failure(s)"
  exit 1
fi
echo "grafana_step_test: all passed"
