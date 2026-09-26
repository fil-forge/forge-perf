#!/usr/bin/env bash
# Runs one set several times, each run through forge-perf-run.service, so every
# run keeps the unit's watchdog, its record and its wipe (docs/runner.md,
# "Campaigns").
#
#   campaign.sh
#       a campaign box, from forge-perf-campaign.service: reads
#       /etc/forge-perf/campaign.json, which the box's user data wrote
#   campaign.sh --set FILE --runs N [--workers W[,W...]] [--size SIZE]
#               [--duration DURATION] [--pairing ID]
#       by hand on a persistent box that is held (status.sh hold)
#
# A campaign box stays at campaign.json's forge_perf_sha and never updates.
# It powers itself off at expires_at through a transient timer, set again at
# every boot, and once its runs are done. Mode calibration runs nothing: the
# box waits for the ceiling measurements. A reboot mid-campaign resumes after
# the last run that ended.
#
# One worker count runs N times, as series campaign. A comma list is a sweep:
# N rounds over the list, reversed every other round (16,32,64,64,32,16 for
# two rounds of 16,32,64), as series calibration, since no value is frozen
# yet. --pairing puts the same pairing ID in each record (pair-<yyyymmdd>-<id>).
#
# For each run it writes pending.json with kind campaign under poll.lock and
# runs `systemctl start --wait forge-perf-run.service`. The poller leaves a
# campaign's pending run alone, and run.sh takes one while the box is held.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }

conf="${FORGE_PERF_CAMPAIGN_CONF:-/etc/forge-perf/campaign.json}"
set_file="" runs="" workers="" size="" duration="" pairing="" from_conf=""
[ $# -gt 0 ] || from_conf=1
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --set) set_file="$2" ;;
    --runs) runs="$2" ;;
    --workers) workers="$2" ;;
    --size) size="$2" ;;
    --duration) duration="$2" ;;
    --pairing) pairing="$2" ;;
    *) usage ;;
  esac
  shift 2
done

runner_init
state="$FORGE_PERF_STATE_DIR"
mkdir -p "$FORGE_PERF_RUNTIME" "$state"
epoch() { jq -rn --arg t "$1" '$t | fromdateiso8601'; }

# poweroff_at TIME: a transient timer, gone at the next boot, when the
# campaign unit sets it again. A box started after its time powers off now.
poweroff_at() {
  local at when
  at="$(epoch "$1")" || die "expires_at '$1' is not a UTC time"
  if [ "$at" -le "$(date -u +%s)" ]; then
    echo "campaign: past expires_at $1; powering off"
    host_op systemctl poweroff
    exit 0
  fi
  host_check systemctl is-active --quiet forge-perf-expire.timer && return 0
  when="$(jq -rn --argjson t "$at" '$t | strftime("%Y-%m-%d %H:%M:%S UTC")')"
  host_op systemd-run --unit forge-perf-expire --on-calendar "$when" --timer-property AccuracySec=1s \
    /usr/bin/systemctl poweroff
  echo "campaign: this box powers off at $1"
}

if [ -n "$from_conf" ]; then
  [ "${FORGE_PERF_MODE:-}" = campaign ] || die "campaign.json drives only a campaign box; use --set here"
  c="$(jq -ce 'objects' "$conf")" || die "$conf is missing or not a JSON object"
  sha="$(jq -r '.forge_perf_sha // ""' <<<"$c")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "$conf has no forge_perf_sha"
  if [ "$(git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)" != "$sha" ]; then
    git -C "$FORGE_PERF_CHECKOUT" checkout --quiet --detach "$sha" || die "cannot check out $sha"
    exec "$BASH" "$0"
  fi
  poweroff_at "$(jq -r '.expires_at // ""' <<<"$c")"
  if [ "$(jq -r .mode <<<"$c")" = calibration ]; then
    echo "campaign: mode calibration; the box waits for the ceiling measurements"
    exit 0
  fi
  set_file="$(jq -r '.set // ""' <<<"$c")" runs="$(jq -r '.runs // ""' <<<"$c")"
  size="$(jq -r '.size // ""' <<<"$c")" duration="$(jq -r '.duration // ""' <<<"$c")"
  workers="$(jq -r '.workers // [] | map(tostring) | join(",")' <<<"$c")"
elif [ "${FORGE_PERF_MODE:-persistent}" != campaign ] && [ ! -e "$state/hold" ]; then
  die "hold the box first (scripts/operator/hold.sh <box> on), so the poller starts nothing between runs"
fi

[[ "$runs" =~ ^[1-9][0-9]*$ ]] && [ "$runs" -le 20 ] || die "runs takes 1 to 20"
[[ -z "$workers" || "$workers" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || die "workers is a number or a comma list"
[[ -z "$pairing" || "$pairing" =~ ^pair-[0-9]{8}-[a-z0-9]{1,12}$ ]] || die "--pairing is pair-<yyyymmdd>-<id>"
case "$set_file" in /*) ;; *) set_file="$FORGE_PERF_CHECKOUT/$set_file" ;; esac
set_json="$(jq -ce 'objects' "$set_file")" || die "$set_file is not a JSON object"

# The order of the runs' worker counts; an empty entry takes the settings file's.
IFS=, read -ra values <<<"$workers"
[ "${#values[@]}" -gt 0 ] || values=("")
order=() series=campaign
[ "${#values[@]}" -eq 1 ] || series=calibration
for ((r = 0; r < runs; r++)); do
  if ((r % 2 == 0)); then
    order+=("${values[@]}")
  else
    for ((i = ${#values[@]} - 1; i >= 0; i--)); do order+=("${values[i]}"); done
  fi
done

exec 7>"$FORGE_PERF_RUNTIME/campaign.lock"
if command -v flock >/dev/null; then
  flock -n 7 || die "another campaign is going"
fi
# A campaign's pending run never outlives it: the poller would leave it alone.
own_pending() { [ "$(jq -r '.kind // ""' "$1" 2>/dev/null)" = campaign ]; }
clean_pending() {
  local f
  for f in "$state/pending.json" "$state/pending.json.rejected"; do
    ! own_pending "$f" || rm -f "$f"
  done
}
trap clean_pending EXIT

# Progress survives a reboot on a campaign box, keyed by the campaign itself.
key="$(jq -cS --argjson set "$set_json" --arg w "$workers" --arg r "$runs" --arg s "$size" --arg d "$duration" \
  --arg p "$pairing" --arg sha "${sha:-}" -n '[$set, $w, $r, $s, $d, $p, $sha]' | cksum | cut -d' ' -f1)"
progress="$state/campaign-progress.json"
start=0
if [ -n "$from_conf" ] && [ "$(jq -r '.key // ""' "$progress" 2>/dev/null)" = "$key" ]; then
  start="$(jq '.done' "$progress")"
fi

total="${#order[@]}"
for ((i = start; i < total; i++)); do
  w="${order[i]}"
  exec 8>"$FORGE_PERF_RUNTIME/poll.lock"
  if command -v flock >/dev/null; then
    flock -w 300 8 || die "a poll has held poll.lock for 5 minutes"
  fi
  jq -n --argjson set "$set_json" --arg series "$series" --arg w "$w" --arg size "$size" \
    --arg duration "$duration" --arg pairing "$pairing" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def opt($k; $v): if $v == "" then {} else {($k): $v} end;
    {kind: "campaign", series: $series, set: $set, superseded: 0, first_seen_at: $at,
     pairing_id: (if $pairing == "" then null else $pairing end)}
    + opt("workers"; $w) + opt("size"; $size) + opt("duration"; $duration)' | write_durable "$state/pending.json"
  exec 8>&-
  echo "campaign: run $((i + 1)) of $total, series $series, workers ${w:-from the settings file}"
  host_op systemctl start --wait forge-perf-run.service ||
    echo "campaign: run $((i + 1)) ended with a failure; its record says why" >&2
  # The poller retries a failed run it dispatched; a campaign's are its own.
  ! own_pending "$state/last-run.json" || rm -f "$state/last-run.json"
  clean_pending
  [ -z "$from_conf" ] ||
    jq -n --arg key "$key" --argjson n "$((i + 1))" '{key: $key, done: $n}' | write_durable "$progress"
done
echo "campaign: $total run(s) done"

if [ -n "$from_conf" ]; then
  # Whatever the runs' own uploads left, before the box goes away.
  for attempt in 1 2 3; do
    "$here/outbox.sh" flush && break
    [ "$attempt" -eq 3 ] || sleep "${FORGE_PERF_FLUSH_RETRY_S:-60}"
  done
  echo "campaign: powering off"
  host_op systemctl poweroff
fi
