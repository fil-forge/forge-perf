#!/usr/bin/env bash
# Runs the experiment the poller planned in state/experiment.json: the current
# main set and the same set with one image swapped, A then B, or A B B A for
# two pairs, each run through forge-perf-run.service (docs/runner.md,
# "Experiments").
#
#   experiment.sh
#
# forge-perf-experiment.service runs it; poll.sh starts that unit. While it
# holds experiment.lock the poller counts a run as going, so no live run and
# no update starts between the runs of a pair. For each run it writes
# state/pending-experiment.json under poll.lock and runs `systemctl start
# --wait forge-perf-run.service`; run.sh takes that file in preference to
# pending.json, records the run as series experiment and leaves
# last-started.json and pending.json as they were.
#
# It writes status/<id>.json to the requests bucket as it goes: running, then
# done with the comparison, or failed with the reason. The first run that
# leaves no record, or a record with no data, ends the experiment; so do a
# hold, a stop request and a refusal by run.sh. Either way the request is
# deleted and state/experiment.json removed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

[ $# -eq 0 ] || die "usage: experiment.sh"
runner_init
state="$FORGE_PERF_STATE_DIR"
exp="$state/experiment.json" dir="$state/experiment" pending="$state/pending-experiment.json"
mkdir -p "$FORGE_PERF_RUNTIME" "$dir/records"
limited() { timeout --kill-after=10 "${FORGE_PERF_CALL_TIMEOUT:-60}" "$@"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

exec 7>"$FORGE_PERF_RUNTIME/experiment.lock"
if command -v flock >/dev/null; then
  flock -n 7 || { echo "experiment: another experiment holds the lock"; exit 0; }
fi
[ -e "$exp" ] || { echo "experiment: nothing planned"; exit 0; }
id="$(jq -re '.id | strings' "$exp")" || die "$exp has no id"
total="$(jq '.order | length' "$exp")"

# status STATE [REASON]: status/<id>.json from the runs so far, in
# $FORGE_PERF_RUNTIME/status.json and then the bucket. Status 1 when it did
# not go up.
status() {
  local out="$FORGE_PERF_RUNTIME/status.json"
  python3 "$here/experiment.py" status --id "$id" --state "$1" ${2:+--reason "$2"} --experiment "$exp" \
    --records "$dir/records" --noise-dir "$FORGE_PERF_CHECKOUT/calibration/noise" --box "$FORGE_PERF_BOX_ID" \
    --instance-type "$(imds instance-type 2>/dev/null || echo unknown)" --now "$(now)" >"$out" || return 1
  jq -r '"experiment \(.id): \(.state)\(if .reason then " (\(.reason))" else "" end)"' "$out"
  put_status "$id" <"$out"
}

# close STATE [REASON]: the last status, then the request, the plan and the
# records go. A request that cannot be deleted stays listed as finished, so
# the poller deletes it and never queues it again; a last status that did not
# go up waits in experiments/unsent/ for the poller to send.
closed=""
close() {
  closed=1
  status "$@" || cp "$FORGE_PERF_RUNTIME/status.json" "$state/experiments/unsent/$id.json"
  : >"$state/experiments/finished/$id"
  delete_request "$id" || true
  rm -f "$exp" "$pending" "$pending.rejected" "$dir/last-run.json"
  rm -rf "${dir:?}/records"
}
mkdir -p "$state/experiments/finished" "$state/experiments/unsent"

stopping=""
on_exit() {
  local rc=$?
  trap - EXIT
  if [ -z "$closed" ]; then
    close failed "${stopping:-the experiment stopped on an error}"
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'stopping="the experiment was stopped"; exit 143' TERM
trap 'stopping="the experiment was stopped"; exit 130' INT

status running || true
for ((i = 0; i < total; i++)); do
  role="$(jq -r --argjson i "$i" '.order[$i]' "$exp")"
  n="run $((i + 1)) of $total ($role)"
  if [ -e "$state/hold" ]; then
    close failed "the box was held before $n"
    exit 0
  fi
  exec 8>"$FORGE_PERF_RUNTIME/poll.lock"
  if command -v flock >/dev/null; then
    flock -w 300 8 || die "a poll has held poll.lock for 5 minutes"
  fi
  rm -f "$dir/last-run.json" "$pending.rejected"
  jq --arg role "$role" --arg at "$(now)" '{kind: "experiment", set: .sets[$role], superseded: 0,
    first_seen_at: $at, pairing_id, experiment: (.experiment + {role: $role}),
    overrides: (if $role == "branch" then .overrides else {} end)}' "$exp" | write_durable "$pending"
  exec 8>&-
  echo "experiment $id: $n"
  host_op systemctl start --wait forge-perf-run.service || true
  if [ -e "$pending.rejected" ]; then
    close failed "run.sh refused $n before it started"
    exit 0
  fi
  if [ -e "$pending" ]; then
    close failed "$n did not start"
    exit 0
  fi
  if ! run_id="$(jq -re '.run_id | strings' "$dir/last-run.json" 2>/dev/null)"; then
    close failed "$n left no run ID"
    exit 0
  fi
  jq --arg role "$role" --arg id "$run_id" '.runs += [{role: $role, run_id: $id}]' "$exp" | write_durable "$exp"
  class="$(jq -r '.outcome.class' "$dir/records/$run_id.json" 2>/dev/null || echo none)"
  case "$class" in
    none) close failed "the $role run $run_id left no record"; exit 0 ;;
    no_data) close failed "the $role run $run_id recorded no data"; exit 0 ;;
  esac
  [ $((i + 1)) -eq "$total" ] || status running || true
done
close final
