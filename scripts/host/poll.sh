#!/usr/bin/env bash
# One poll pass (docs/runner.md, "Polling"): resolve the set under test, keep
# at most one pending run, start it when the box is free, and report.
#
#   poll.sh [--nightly]
#
# forge-perf-poll.timer runs it every five minutes, forge-perf-nightly.timer
# with --nightly at 03:00 UTC. A pass:
#
#   1. settles the last run it started: a set an infrastructure failure
#      stopped goes back to pending, 15 minutes later, up to three times;
#   2. resolves the set: smelt and harness heads with `git ls-remote`, every
#      image in config/images.tracked from GHCR, each call under `timeout 60`;
#   3. updates pending.json: a set that differs from the last one started
#      replaces what is pending, and --nightly writes a nightly run whatever
#      changed;
#   4. between runs, and unless the box is held: starts update.sh when
#      origin moved or the last update.sh did not finish for this checkout,
#      otherwise starts the pending run, or flushes the outbox when nothing
#      can start;
#   5. writes the heartbeat to published/<box>/heartbeat.json.
#
# Exit status 1 when the set could not be resolved, update.sh failed, or the
# heartbeat did not go up; the pass still does everything else.
#
# SC2016: jq programs are single-quoted on purpose.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

nightly=""
case "${1:-}" in
  "") ;;
  --nightly) nightly=1 ;;
  *) die "usage: poll.sh [--nightly]" ;;
esac

runner_init
state="$FORGE_PERF_STATE_DIR" cfg="$FORGE_PERF_CHECKOUT/config"
mkdir -p "$FORGE_PERF_RUNTIME" "$state"
# A timer pass that finds the previous pass still going is skipped; the
# nightly pass waits for it.
exec 8>"$FORGE_PERF_RUNTIME/poll.lock"
if command -v flock >/dev/null; then
  if [ -n "$nightly" ]; then
    flock -w 200 8 || die "poll.lock was held for 200 s"
  else
    flock -n 8 || { echo "poll: the previous pass is still going"; exit 0; }
  fi
elif ! host_ops_skipped; then
  die "flock is missing"
fi

# shellcheck source=../../config/harness.conf
. "$cfg/harness.conf"
# shellcheck source=../../config/smelt.conf
. "$cfg/smelt.conf"
INFRA_REASONS="image_pull_failed secrets_unavailable s3_unreachable mirror_fetch_failed go_module_fetch_failed"
RETRIES=3 RETRY_AFTER=900
bucket="${FORGE_PERF_RESULTS_BUCKET:-forge-perf-results-654654381893}"
status=0

limited() { timeout --kill-after=10 "${FORGE_PERF_CALL_TIMEOUT:-60}" "$@"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# The trigger key of the set on stdin: the inputs a change of which starts a run.
key() { jq -cS '{smelt, harness: .harness.sha, images}'; }
same_key() { [ -e "$1" ] && [ "$(jq '.set // .' "$1" | key)" = "$(key <<<"$2")" ]; }
put() { write_durable "$state/$1"; }

# --- 1. the last run ---------------------------------------------------------------

# run.sh leaves last-run.json when a run it took from pending.json ends. An
# infrastructure reason puts the set back: last-started.json returns to the
# set before it, and the set is pending again 15 minutes later, unless a
# newer set is already pending. After the third retry the set stays in
# last-started.json and waits for the nightly run.
settle_last_run() {
  local f="$state/last-run.json" infra attempt id
  [ -e "$f" ] || return 0
  # A campaign retries nothing; campaign.sh removes its own.
  [ "$(jq -r '.kind // ""' "$f")" != campaign ] || { rm -f "$f"; return 0; }
  id="$(jq -r .run_id "$f")" attempt="$(jq '.attempt // 0' "$f")"
  infra="$(jq -r --arg infra "$INFRA_REASONS" \
    '[.reasons[]? | select(. as $r | $infra | split(" ") | index($r))] | join(" ")' "$f")"
  if [ -n "$infra" ] && [ "$attempt" -lt "$RETRIES" ]; then
    if jq -e '.previous_started != null' "$f" >/dev/null; then
      jq .previous_started "$f" | put last-started.json
    else
      rm -f "$state/last-started.json"
    fi
    if [ -e "$state/pending.json" ]; then
      jq '.superseded += 1' "$state/pending.json" | put pending.json
      echo "poll: $id stopped by $infra; the pending set covers it"
    else
      jq --arg at "$(now)" --argjson after "$(($(date +%s) + RETRY_AFTER))" \
        '{kind, set, superseded, attempt: (.attempt + 1), first_seen_at: $at, not_before: $after}' "$f" |
        put pending.json
      echo "poll: $id stopped by $infra; retry $((attempt + 1)) of $RETRIES in $((RETRY_AFTER / 60)) minutes"
    fi
  elif [ -n "$infra" ]; then
    echo "poll: $id stopped by $infra after $RETRIES retries; the set waits for the nightly run"
  fi
  rm -f "$f"
}

# --- 2. the set ----------------------------------------------------------------------

# ls_remote URL GIT...: the 40-hex head of main.
ls_remote() {
  local url="$1" out
  shift
  out="$(limited "$@" ls-remote "$url" refs/heads/main)" || return 1
  out="${out%%[[:space:]]*}"
  [[ "$out" =~ ^[0-9a-f]{40}$ ]] && echo "$out"
}

# ghcr_digest REPO:TAG: the index digest, anonymously (docs/runner.md).
ghcr_digest() {
  local repo="${1#ghcr.io/}" token digest
  repo="${repo%:*}"
  token="$(limited curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)" || return 1
  digest="$(limited curl -fsSI -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/$repo/manifests/${1##*:}" |
    awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }' | tr -d '\r')" || return 1
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] && echo "$digest"
}

# resolve: the set on stdout, or a message and status 1.
resolve() {
  local smelt harness pinned=true main=null images='{}' var ref digest dir
  if [ -n "${SMELT_REF:-}" ]; then
    smelt="$SMELT_REF"
  else
    smelt="$(ls_remote "${FORGE_PERF_SMELT_URL:-https://github.com/$SMELT_REPO.git}" git)" ||
      { echo "poll: cannot resolve smelt main" >&2; return 1; }
  fi
  # While SQ_PIN is set the pin runs and harness main is not looked up, which
  # would read the harness credential every five minutes.
  harness="${SQ_PIN:-}"
  if [ -z "$harness" ]; then
    dir="$(mktemp -d "$FORGE_PERF_RUNTIME/poll-secrets.XXXXXX")"
    if harness_git "$dir"; then
      harness="$(ls_remote "$HARNESS_URL" "${HARNESS_GIT[@]}")" || harness=""
    fi
    rm -rf "$dir"
    [ -n "$harness" ] || { echo "poll: cannot resolve harness main" >&2; return 1; }
    pinned=false main="\"$harness\""
  fi
  while read -r var ref; do
    digest="$(ghcr_digest "$ref")" || { echo "poll: cannot resolve $ref ($var)" >&2; return 1; }
    images="$(jq -c --arg r "$ref" --arg d "$digest" '.[$r] = $d' <<<"$images")"
  done < <(sed 's/#.*//' "$cfg/images.tracked" | awk 'NF == 2')
  jq -nc --arg smelt "$smelt" --arg sha "$harness" --argjson pinned "$pinned" --argjson main "$main" \
    --argjson images "$images" --arg at "$(now)" \
    '{smelt: $smelt, harness: {sha: $sha, pinned: $pinned, main: $main}, images: $images, resolved_at: $at}'
}

# --- 3. pending.json -------------------------------------------------------------------

# want SET: latest wins, one pending run. A newer set replaces the pending
# one and counts it in superseded; a pending nightly stays nightly.
want() {
  local set="$1" p="$state/pending.json"
  # campaign.sh's run is its own; the newest set is pending once it is done.
  if [ "$(jq -r '.kind // ""' "$p" 2>/dev/null)" = campaign ]; then
    echo "poll: a campaign run is pending; the set waits"
  elif [ -n "$nightly" ]; then
    jq -n --arg at "$(now)" --argjson set "$set" --argjson same "$(same_key "$p" "$set" && echo true || echo false)" \
      --argjson p "$(jq -c . "$p" 2>/dev/null || echo null)" \
      '{kind: "nightly", set: $set, first_seen_at: ($p.first_seen_at // $at),
        superseded: (if $p == null then 0 else $p.superseded + (if $same then 0 else 1 end) end)}' | put pending.json
    echo "poll: nightly run pending"
  elif same_key "$state/last-started.json" "$set" || same_key "$p" "$set" ||
    same_key "$state/pending.json.rejected" "$set"; then
    return 0
  elif [ -e "$p" ]; then
    jq --argjson set "$set" '{kind, set: $set, first_seen_at, superseded: (.superseded + 1)}' "$p" | put pending.json
    echo "poll: a newer set replaces the pending one ($(jq .superseded "$p") superseded)"
  else
    jq -n --arg at "$(now)" --argjson set "$set" '{kind: "trigger", set: $set, first_seen_at: $at, superseded: 0}' |
      put pending.json
    echo "poll: new set pending"
  fi
}

# --- 4. between runs --------------------------------------------------------------------

# background UNIT SCRIPT ARGS...: a transient unit, so a long upload or a
# provision is not cut off by this unit's TimeoutStartSec.
background() {
  local unit="$1"
  shift
  host_op systemd-run --unit "$unit" --collect --no-block --quiet --setenv "AWS_REGION=${AWS_REGION:-us-east-2}" \
    --property RuntimeMaxSec=45min /bin/bash "$@" || echo "poll: $unit is already running" >&2
}

# update: start update.sh when origin's head differs from the checkout's, or
# when update.sh has not finished for the checkout's HEAD (its last step writes
# state/updated-rev). update.sh resets the checkout before it provisions, so
# after a failed provision HEAD already equals origin, and only updated-rev
# shows the host is behind. While update.sh is not running for such a HEAD,
# each pass counts an update failure, which the heartbeat reports in
# poll_failures, and starts it again. update.sh arrives with the box's
# provisioning; a campaign box, and a laptop in skip mode, never update
# (FORGE_PERF_POLL_UPDATES=1 lets the tests drive it in skip mode).
update() {
  local head remote finished ref="${FORGE_PERF_REF:-main}"
  { ! host_ops_skipped || [ "${FORGE_PERF_POLL_UPDATES:-}" = 1 ]; } &&
    [ "${FORGE_PERF_MODE:-persistent}" = persistent ] && [ -e "$here/update.sh" ] || return 1
  head="$(git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)"
  finished="$(cat "$state/updated-rev" 2>/dev/null || true)"
  remote="$(limited git -C "$FORGE_PERF_CHECKOUT" ls-remote origin "refs/heads/$ref" | cut -f1)" ||
    { echo "poll: cannot reach forge-perf's origin" >&2; remote=""; }
  if [ -n "$remote" ] && [ "$remote" != "$head" ]; then
    echo "poll: forge-perf moved to ${remote:0:12}; updating before the next run"
  elif [ "$finished" != "$head" ]; then
    if host_check systemctl is-active --quiet forge-perf-update.service; then
      echo "poll: update.sh is still going for ${head:0:12}; no run starts"
      return 0
    fi
    update_failures=$((update_failures + 1)) status=1
    echo "poll: update.sh has not finished for ${head:0:12} (failure $update_failures); running it again" >&2
  else
    return 1
  fi
  background forge-perf-update "$here/update.sh"
}

flush() {
  [ -n "$(ls -A "$FORGE_PERF_OUTBOX" 2>/dev/null)" ] || return 0
  if host_ops_skipped; then
    "$here/outbox.sh" flush || echo "poll: the outbox keeps files for the next pass" >&2
  else
    background forge-perf-outbox "$here/outbox.sh" flush
  fi
}

# ready: a run is pending, its not_before has passed, and it has workers.
ready() {
  local p="$state/pending.json" workers type
  [ -e "$p" ] || return 1
  if [ "$(jq '.not_before // 0' "$p")" -gt "$(date +%s)" ]; then
    echo "poll: the pending retry waits until $(jq '.not_before' "$p")"
    return 1
  fi
  workers="$(jq -r '.workers // empty' "$p")"
  [ -z "$workers" ] || return 0
  type="$(imds instance-type 2>/dev/null)" || type=""
  if [ -z "$type" ] || [ ! -r "$cfg/settings/$type.env" ]; then
    echo "poll: no settings file for instance type ${type:-unknown}; the pending run waits"
    return 1
  fi
  # shellcheck disable=SC1090
  workers="$(. "$cfg/settings/$type.env" && echo "${WORKERS:-}")"
  [ -n "$workers" ] && return 0
  echo "poll: WORKERS is empty for this instance type; the pending run waits"
  return 1
}

# dispatch: start the pending run, unless an outbox flush is still uploading
# beside where the run would measure; the run's own upload flushes the rest.
dispatch() {
  if ! host_ops_skipped && systemctl is-active --quiet forge-perf-outbox.service; then
    echo "poll: the outbox flush is going; the pending run starts after it"
    return 0
  fi
  host_op systemctl start --no-block forge-perf-run.service
  echo "poll: started forge-perf-run for the pending $(jq -r .kind "$state/pending.json") run"
}

# --- the pass ------------------------------------------------------------------------------

active="" held=""
! run_active || active=1
[ -n "$active" ] || settle_last_run

failures="$(cat "$state/poll-failures" 2>/dev/null || echo 0)"
if resolved="$(resolve)"; then
  failures=0
  want "$resolved"
else
  failures=$((failures + 1)) status=1
  # A nightly run still starts, on the newest set this box has.
  for f in pending.json last-started.json; do
    if [ -n "$nightly" ] && [ -e "$state/$f" ]; then
      want "$(jq -c '.set // .' "$state/$f")"
      break
    fi
  done
fi
echo "$failures" | put poll-failures
update_failures="$(cat "$state/update-failures" 2>/dev/null || echo 0)"

# The hold is read after resolution, which can take minutes, so a hold set
# during it still stops this pass's dispatch. run.sh checks it again under
# poll.lock.
[ ! -e "$state/hold" ] || held=1
if [ -n "$active" ]; then
  echo "poll: a run is going; the pending run starts after it"
elif [ -n "$held" ]; then
  echo "poll: the box is held; nothing starts (scripts/host/status.sh release)"
  flush
elif update; then
  :
elif ready; then
  dispatch
else
  flush
fi
# A pass that finds update.sh finished for HEAD clears the count.
[ "$(cat "$state/updated-rev" 2>/dev/null)" != "$(git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)" ] ||
  update_failures=0
echo "$update_failures" | put update-failures

# --- 5. the heartbeat --------------------------------------------------------------------

run_id=null started=null box_state=idle
[ ! -e "$state/hold" ] || box_state=held
[ -z "$active" ] || box_state=running
if [ -n "$active" ] && [ -e "$state/current.json" ]; then
  run_id="$(jq -c '.run_id // null' "$state/current.json")"
  started="$(jq -c --argjson id "$run_id" 'if .run_id == $id then .time.run_started_at else null end' \
    "$state/runner.json" 2>/dev/null || echo null)"
fi
jq -n --arg box "$FORGE_PERF_BOX_ID" --arg at "$(now)" --arg sha "$(git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)" \
  --arg state "$box_state" \
  --argjson run_id "$run_id" --argjson started "$started" --argjson failures "$((failures + update_failures))" \
  --argjson kind "$(jq -c '.kind // null' "$state/pending.json" 2>/dev/null || echo null)" \
  '{box: $box, at: $at, forge_perf_sha: $sha, state: $state, run_id: $run_id, run_started_at: $started,
    pending_kind: $kind, poll_failures: $failures}' >"$FORGE_PERF_RUNTIME/heartbeat.json"
if ! limited aws s3api put-object --bucket "$bucket" --key "published/$FORGE_PERF_BOX_ID/heartbeat.json" \
  --body "$FORGE_PERF_RUNTIME/heartbeat.json" --content-type application/json >/dev/null; then
  echo "poll: the heartbeat did not go up" >&2
  status=1
fi
exit "$status"
