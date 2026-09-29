#!/usr/bin/env bash
# Behavior of experiment.sh against stubs: systemctl takes the run
# experiment.sh left in pending-experiment.json, as run.sh does, and records
# it from the valid fixture's record with the rates in $D/rates (role median
# p5 class per line); aws keeps the status files in $D/status/ and logs the
# deleted requests; id answers 0, so the script runs as on the box without
# FORGE_PERF_HOST_OPS=skip.
#
# SC2015: `a && b || fail` is intended; fail runs when either check fails.
# shellcheck disable=SC2015
set -euo pipefail

host="$(cd "$(dirname "$0")/.." && pwd -P)"
repo="$(cd "$host/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/experiment-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export D="$work/d" FIXTURES="$host/fixtures"
mkdir -p "$work/bin"
unset INVOCATION_ID FORGE_PERF_LOCK_HELD FORGE_PERF_HOST_OPS
export PYTHONDONTWRITEBYTECODE=1 FORGE_PERF_IMDS_URL=http://127.0.0.1:9

printf '#!/usr/bin/env bash\necho 0\n' >"$work/bin/id"
cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$D/systemctl.log"
[ "$*" = "start --wait forge-perf-run.service" ] || exit 0
p="$FORGE_PERF_STATE_DIR/pending-experiment.json"
[ ! -e "$D/refuse" ] || { mv "$p" "$p.rejected"; exit 2; }
[ ! -e "$D/held" ] || exit 0
jq -c . "$p" >>"$D/runs.log"
n="$(wc -l <"$D/runs.log" | tr -d ' ')"
id="main-20261001t12000${n}z"
read -r median p5 class < <(sed -n "${n}p" "$D/rates")
mkdir -p "$FORGE_PERF_STATE_DIR/experiment/records"
jq --arg id "$id" --argjson m "$median" --argjson p "$p5" --arg c "$class" --slurpfile pending "$p" '
  .run_id = $id | .series = "experiment" | .experiment = $pending[0].experiment
  | .outcome.class = $c | .drill.results.ingest_median_bytes_per_s = $m | .drill.results.ingest_p5_bytes_per_s = $p
  | if $c == "no_data" then .drill.results = null else . end' \
  "$FIXTURES/valid/expected.json" >"$FORGE_PERF_STATE_DIR/experiment/records/$id.json"
jq -n --arg id "$id" '{run_id: $id, reasons: []}' >"$FORGE_PERF_STATE_DIR/experiment/last-run.json"
rm "$p"
STUB
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
key() { while [ "$1" != --key ]; do shift; done; echo "$2"; }
case " $* " in
  *" put-object "*)
    [ ! -e "$D/status-down" ] || exit 1
    k="$(key "$@")"
    while [ "$1" != --body ]; do shift; done
    mkdir -p "$D/status"
    cp "$2" "$D/status/${k#status/}"
    jq -r .state "$2" >>"$D/states" ;;
  *" delete-object "*) key "$@" >>"$D/deleted" ;;
  *) echo "aws stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

fail() {
  echo "FAIL: $*" >&2
  sed 's/^/  | /' "$work/out" >&2 || true
  exit 1
}
state="$work/box/state"
COMMIT=0123456789abcdef0123456789abcdef01234567
ID="ingot-pr123-${COMMIT:0:12}-17000000001"

# setup PAIRS RATES...: a planned experiment of PAIRS pairs, and the rates each
# run records in order ("median p5 class").
setup() {
  local pairs="$1"
  shift
  rm -rf "$work/box" "$D"
  mkdir -p "$D" "$state" "$work/box/run" "$work/box/outbox"
  printf '%s\n' "$@" >"$D/rates"
  printf '%s\n' FORGE_PERF_BOX_ID=main "FORGE_PERF_CHECKOUT=$repo" FORGE_PERF_REQUESTS_BUCKET=test-requests \
    >"$work/box/box.conf"
  jq -n --arg id "$ID" --arg c "$COMMIT" --argjson pairs "$pairs" '{schema: "forge-perf.request/v1", id: $id,
    service: "ingot", image: "ghcr.io/fil-forge/ingot", digest: ("sha256:" + "b" * 64), tag: "pr-123-0123456",
    commit: $c, repository: "fil-forge/ingot", pr: 123, requested_at: "2026-10-01T12:00:00Z", pairs: $pairs}' \
    >"$work/request.json"
  python3 "$host/experiment.py" validate --request "$work/request.json" --id "$ID" >"$work/checked.json"
  jq -n '{smelt: ("1" * 40), harness: {sha: ("2" * 40), pinned: true, main: null},
    images: {"ghcr.io/fil-forge/ingot:main": ("sha256:" + "a" * 64), "ghcr.io/fil-forge/piri:main": ("sha256:" + "c" * 64)}}' \
    >"$work/set.json"
  python3 "$host/experiment.py" plan --request "$work/checked.json" --set "$work/set.json" >"$state/experiment.json"
  # The live series' state, which the experiment leaves alone.
  jq . "$work/set.json" >"$state/last-started.json"
  jq '{kind: "trigger", set: ., superseded: 0}' "$work/set.json" >"$state/pending.json"
  cp "$state/last-started.json" "$work/last-started.json"
  cp "$state/pending.json" "$work/pending.json"
}
experiment() {
  local got=0
  env FORGE_PERF_BOX_CONF="$work/box/box.conf" FORGE_PERF_STATE_DIR="$state" FORGE_PERF_RUNTIME="$work/box/run" \
    FORGE_PERF_OUTBOX="$work/box/outbox" bash "$host/experiment.sh" >"$work/out" 2>&1 || got=$?
  [ "$got" = "$1" ] || fail "experiment.sh exited $got, wanted $1"
}
final() { jq -r "$1" "$D/status/$ID.json"; }
runs() { jq -r "$1" "$D/runs.log" | paste -sd' ' -; }
closed() {
  [ ! -e "$state/experiment.json" ] && [ ! -e "$state/pending-experiment.json" ] &&
    [ -e "$state/experiments/finished/$ID" ] && grep -qx "requests/$ID.json" "$D/deleted" ||
    fail "the experiment was not closed"
  cmp -s "$state/last-started.json" "$work/last-started.json" && cmp -s "$state/pending.json" "$work/pending.json" ||
    fail "the live series' state changed"
}

setup 1 "1.0e9 0.8e9 valid" "1.1e9 0.9e9 valid"
experiment 0
[ "$(runs '"\(.kind)/\(.experiment.role)/\(.pairing_id)/\(.overrides | keys | join(","))"')" = \
  "experiment/main/exp-$ID/ experiment/branch/exp-$ID/ghcr.io/fil-forge/ingot:main" ] || fail "runs $(cat "$D/runs.log")"
[ "$(runs '.set.images["ghcr.io/fil-forge/ingot:main"][7:8]')" = "a b" ] || fail "sets"
[ "$(jq -r '.experiment | "\(.request_id) \(.service) \(.repository) \(.pr) \(.commit)"' "$D/runs.log" | sort -u)" = \
  "$ID ingot fil-forge/ingot 123 $COMMIT" ] || fail "experiment block"
[ "$(paste -sd' ' - <"$D/states")" = "running running done" ] || fail "states $(cat "$D/states")"
[ "$(final '.comparison == {median_delta_pct: 10, p5_delta_pct: 12.5, noise_median_pct: 3.5, noise_p5_pct: 11,
  verdict: "faster"}')" = true ] || fail "comparison $(final .comparison)"
[ "$(final '[.runs[] | "\(.role):\(.run_id)"] | join(" ")')" = "main:main-20261001t120001z branch:main-20261001t120002z" ] ||
  fail "status runs $(final .runs)"
closed
echo "ok: one pair runs main then branch, ends done with the comparison, and leaves the live series' state alone"

setup 2 "1.0e9 0.8e9 valid" "1.0e9 0.8e9 valid" "1.0e9 0.8e9 availability_warning" "1.0e9 0.8e9 valid"
experiment 0
[ "$(runs .experiment.role)" = "main branch branch main" ] || fail "order $(runs .experiment.role)"
[ "$(final '"\(.state) \(.comparison.verdict)"')" = "done within noise" ] || fail "two pairs $(final .)"
echo "ok: two pairs run main, branch, branch, main"

setup 2 "1.0e9 0.8e9 valid" "0 0 no_data" "1.0e9 0.8e9 valid" "1.0e9 0.8e9 valid"
experiment 0
[ "$(runs .experiment.role)" = "main branch" ] || fail "runs after no data $(runs .experiment.role)"
[ "$(final '"\(.state) \(.reason) \(.runs | length)"')" = "failed the branch run main-20261001t120002z recorded no data 2" ] ||
  fail "no data $(final .)"
closed
echo "ok: a run with no data ends the experiment as failed"

setup 1 "1.0e9 0.8e9 valid" "1.0e9 0.8e9 failed"
experiment 0
[ "$(final '"\(.state) \(.reason)"')" = "failed the branch run main-20261001t120002z ended failed" ] || fail "failed $(final .)"
echo "ok: a run that failed leaves no comparison"

setup 1
touch "$D/refuse"
experiment 0
[ "$(final '"\(.state) \(.reason)"')" = "failed run.sh refused run 1 of 2 (main) before it started" ] || fail "refused $(final .)"
closed
[ ! -e "$state/pending-experiment.json.rejected" ] || fail "rejected file left"
setup 1
touch "$D/held"
experiment 0
[ "$(final '"\(.state) \(.reason)"')" = "failed run 1 of 2 (main) did not start" ] || fail "held run $(final .)"
closed
setup 1
echo '{"at": "2026-10-01T12:00:00Z"}' >"$state/hold"
experiment 0
[ "$(final '"\(.state) \(.reason)"')" = "failed the box was held before run 1 of 2 (main)" ] || fail "hold $(final .)"
[ ! -e "$D/runs.log" ] || fail "a held box ran"
echo "ok: a refusal, a run that did not start and a hold each end the experiment as failed"

setup 1 "1.0e9 0.8e9 valid" "1.0e9 0.8e9 valid"
touch "$D/status-down"
experiment 0
[ "$(jq -r .state "$state/experiments/unsent/$ID.json")" = "done" ] || fail "the last status was not kept to send"
echo "ok: a last status that did not go up waits for the poller"

rm -rf "$state"
mkdir -p "$state"
experiment 0
grep -q "nothing planned" "$work/out" || fail "no plan"
echo "experiment: all tests passed"
