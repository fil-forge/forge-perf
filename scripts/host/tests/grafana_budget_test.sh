#!/usr/bin/env bash
# The Grafana step's time budget (runlib.sh grafana_export, docs/runner.md
# "Tracing"): GRAFANA_TIMEOUT_S for a run without spans, plus
# GRAFANA_TRACE_S_PER_GB for each GB of traces.jsonl, up to
# GRAFANA_TIMEOUT_MAX_S. timeout is stubbed on PATH to run over, so the step's
# "ran over" line names the budget; the time left, which a second boundary can
# shave by one, stays out of the check. The trace files are sparse, so a 5 GB
# file costs no disk.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2016
set -euo pipefail
# The CI runner starts steps under systemd, where lib.sh refuses skip mode.
unset INVOCATION_ID FORGE_PERF_HOST_OPS FORGE_PERF_LOCK_HELD

repo="$(cd "$(dirname "$0")/../../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/grafana-budget-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/checkout/config" "$work/traces"

# timeout --kill-after=5 SECONDS python3 grafana-export.py ...: run over.
cat >"$work/bin/timeout" <<'STUB'
#!/usr/bin/env bash
exit 124
STUB
chmod +x "$work/bin/timeout"
echo "123456:glc_fake" >"$work/creds"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# budget <conf lines> <traces.jsonl size or "none">: the seconds the exporter got.
budget() {
  printf 'GRAFANA_OTLP_ENDPOINT=https://otlp.example.test/otlp\n%s\n' "$1" >"$work/checkout/config/grafana.conf"
  rm -f "$work/traces/traces.jsonl"
  [ "$2" = none ] || { : >"$work/traces/traces.jsonl" && truncate -s "$2" "$work/traces/traces.jsonl"; }
  (
    PATH="$work/bin:$PATH"
    FORGE_PERF_CHECKOUT="$work/checkout" FORGE_PERF_GRAFANA_CREDENTIALS="$work/creds"
    FORGE_PERF_HOST_OPS=skip FORGE_PERF_IMDS_URL=http://127.0.0.1:9
    # shellcheck source=../lib.sh
    . "$repo/scripts/host/lib.sh"
    # shellcheck source=../runlib.sh
    . "$repo/scripts/host/runlib.sh"
    step() { :; }
    grafana_export "$work/runner.json" "$work/record.json" "$work/traces" 2>&1 >/dev/null
  ) | sed -n 's/^grafana: ran over \([0-9]*\)s.*/\1/p' | grep . || echo "not run"
}

committed="$(cat "$repo/config/grafana.conf")"

got="$(budget "$committed" none)"
[ "$got" = "120" ] || fail "a run without spans got '$got', not 120 s"

# A tier 2 nightly at 10%: about 1.1 GB of spans.
got="$(budget "$committed" 1100000000)"
[ "$got" = "285" ] || fail "1.1 GB of spans got '$got', not 120 + 165 s"

got="$(budget "$committed" 2000000000)"
[ "$got" = "420" ] || fail "2 GB of spans got '$got', not 120 + 300 s"

got="$(budget "$committed" 5000000000)"
[ "$got" = "600" ] || fail "5 GB of spans got '$got', not the 600 s cap"

# A cap below the base leaves the base.
got="$(budget $'GRAFANA_TIMEOUT_S=120\nGRAFANA_TIMEOUT_MAX_S=60' 2000000000)"
[ "$got" = "120" ] || fail "a cap under the base got '$got'"

# Malformed values fall back to the defaults.
got="$(budget $'GRAFANA_TRACE_S_PER_GB=fast\nGRAFANA_TIMEOUT_MAX_S=-1' 2000000000)"
[ "$got" = "420" ] || fail "malformed settings got '$got'"

# 0 per GB keeps the flat budget.
got="$(budget $'GRAFANA_TIMEOUT_S=120\nGRAFANA_TRACE_S_PER_GB=0' 2000000000)"
[ "$got" = "120" ] || fail "0 s per GB got '$got'"

if [ "$failures" -ne 0 ]; then
  echo "grafana_budget_test: $failures failure(s)"
  exit 1
fi
echo "grafana_budget_test: all passed"
