#!/usr/bin/env bash
# The box's run state, and its hold.
#
#   status.sh                      the hold, the run in progress, the pending,
#                                  last started and last finished sets, poll
#                                  failures and the timers
#   status.sh hold [--wait-idle]   no run starts until release; with
#                                  --wait-idle, return once no run is going
#   status.sh release              runs start again at the next poll
#
# The hold is /var/lib/forge-perf/state/hold on the root volume, so it
# survives a reboot. It stops the poller from starting runs and updating the
# checkout; a run already going finishes. scripts/operator/hold.sh sets and
# releases it over SSM.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

runner_init
state="$FORGE_PERF_STATE_DIR"
mkdir -p "$state"

show() {
  local name="$1" filter="$2"
  if [ -e "$state/$name" ]; then
    printf '%-13s %s\n' "$name:" "$(jq -c "$filter" "$state/$name")"
  else
    printf '%-13s none\n' "$name:"
  fi
}

case "${1:-}" in
  "")
    show hold .
    if run_active; then echo "run:          going"; else echo "run:          none"; fi
    show current.json .
    show pending.json '{kind, superseded, attempt, not_before, first_seen_at, smelt: .set.smelt}'
    show last-started.json '{smelt, harness: .harness.sha, resolved_at}'
    show last-run.json '{run_id, kind, attempt, reasons}'
    printf '%-13s %s\n' "poll failures:" "$(cat "$state/poll-failures" 2>/dev/null || echo 0)"
    host_read systemctl list-timers 'forge-perf-*' --no-pager
    ;;
  hold)
    [ -e "$state/hold" ] || jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at: $at}' | write_durable "$state/hold"
    echo "held since $(jq -r .at "$state/hold")"
    if [ "${2:-}" = --wait-idle ]; then
      # A poll pass that read the box before the hold may be about to start
      # a run; once it lets poll.lock go, that run counts as going.
      mkdir -p "$FORGE_PERF_RUNTIME"
      exec 8>"$FORGE_PERF_RUNTIME/poll.lock"
      if command -v flock >/dev/null; then
        flock -w 300 8 || die "a poll pass has held poll.lock for 300 s; the hold is set, run this again"
      fi
      exec 8>&-
      while run_active; do
        echo "a run is going; waiting"
        sleep "${FORGE_PERF_HOLD_POLL_SECONDS:-30}"
      done
      echo "idle"
    fi
    ;;
  release)
    rm -f "$state/hold"
    echo "released; the next poll starts what is pending"
    ;;
  *) die "usage: status.sh [hold [--wait-idle] | release]" ;;
esac
