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
#   4. reads the experiment requests in the requests bucket: refuses the ones
#      that break a rule, queues the rest oldest first and writes each its
#      status (docs/runner.md, "Experiments");
#   5. between runs, and unless the box is held: starts update.sh when
#      origin moved or the last update.sh did not finish for this checkout,
#      otherwise starts the pending run, else the oldest queued experiment
#      when the start rules allow, or flushes the outbox when nothing can
#      start;
#   6. writes the heartbeat to published/<box>/heartbeat.json;
#   7. with SLEEP_WHEN_IDLE=1 and nothing left to do, says so in that
#      heartbeat and powers the box off (docs/runner.md, "Sleeping").
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
# shellcheck source=../../config/launch.conf
. "$cfg/launch.conf"
INFRA_REASONS="image_pull_failed secrets_unavailable s3_unreachable mirror_fetch_failed go_module_fetch_failed"
RETRIES=3 RETRY_AFTER=900
bucket="${FORGE_PERF_RESULTS_BUCKET:-forge-perf-results-654654381893}"
status=0
# Experiments: validated requests waiting in queue/, the IDs of finished ones
# (kept 31 days, past the bucket's 30-day expiry, so a request whose delete
# failed never runs twice), the status last sent for each, an experiment's
# last status that experiment.sh could not send, and the day and ID of each
# start.
queue="$state/experiments/queue" finished="$state/experiments/finished" sent="$state/experiments/status"
unsent="$state/experiments/unsent" started_log="$state/experiments/started"
EXPERIMENTS_PER_DAY=4 NEW_REQUESTS_PER_PASS=3 MAX_REQUEST_BYTES=8192
mkdir -p "$queue" "$finished" "$sent" "$unsent"

limited() { timeout --kill-after=10 "${FORGE_PERF_CALL_TIMEOUT:-60}" "$@"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# The trigger key of the set on stdin: the inputs a change of which starts a run.
key() { jq -cS '{smelt, harness: .harness.sha, images}'; }
same_key() { [ -e "$1" ] && [ "$(jq '.set // .' "$1" | key)" = "$(key <<<"$2")" ]; }
# The waker key hash of the set on stdin. The waker cannot look up the harness
# head, so its key leaves the harness out (docs/runner.md, "Sleeping").
waker_key() { jq -cSj '{smelt, images}' | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }
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

# ghcr_has IMAGE DIGEST: 0 when GHCR serves the manifest anonymously, 1 when
# it answers that it does not, 2 when it does not answer.
ghcr_has() {
  local repo="${1#ghcr.io/}" token code
  token="$(limited curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)" || return 2
  code="$(limited curl -sS -o /dev/null -w '%{http_code}' -I -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/$repo/manifests/$2")" || return 2
  case "$code" in
    200) return 0 ;;
    401 | 403 | 404) return 1 ;;
    *) return 2 ;;
  esac
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

# --- 4. experiment requests ---------------------------------------------------------------

# send_status ID ARGS...: status/<id>.json from `experiment.py status ARGS`,
# sent only when it differs from the last one sent in more than its time.
send_status() {
  local id="$1" doc
  shift
  doc="$(python3 "$here/experiment.py" status --id "$id" "$@")" || return 1
  if [ -e "$sent/$id.json" ] &&
    [ "$(jq -cS 'del(.updated_at)' "$sent/$id.json")" = "$(jq -cS 'del(.updated_at)' <<<"$doc")" ]; then
    return 0
  fi
  put_status "$id" <<<"$doc" && printf '%s\n' "$doc" >"$sent/$id.json"
}

# end_request ID STATE ARGS...: the last status, then the request goes. When
# the status cannot be sent the request stays for the next pass.
end_request() {
  local id="$1"
  shift
  send_status "$id" --state "$@" || return 1
  : >"$finished/$id"
  delete_request "$id" || true
  rm -f "${queue:?}/$id.json" "${sent:?}/$id.json"
}

# check_request KEY ID SIZE: queue the request, refuse it, or leave it for the
# next pass when S3 or GHCR does not answer. Status 0 when it is queued.
check_request() {
  local key="$1" id="$2" size="$3" tmp="$FORGE_PERF_RUNTIME/request.json" out rc=0 got=0
  if [ "$size" -gt "$MAX_REQUEST_BYTES" ]; then
    end_request "$id" refused --reason "the request is larger than 8 KiB" || true
    return 1
  fi
  limited aws s3api get-object --bucket "$(requests_bucket)" --key "$key" "$tmp" >/dev/null ||
    { echo "poll: cannot read request $id; the next pass tries again" >&2; return 1; }
  out="$(python3 "$here/experiment.py" validate --request "$tmp" --id "$id" --tracked "$cfg/images.tracked")" || rc=$?
  rm -f "$tmp"
  case "$rc" in
    0) ;;
    1)
      echo "poll: refused request $id: $out"
      end_request "$id" refused --reason "$out" || true
      return 1
      ;;
    *) echo "poll: cannot check request $id" >&2; return 1 ;;
  esac
  ghcr_has "$(jq -r .image <<<"$out")" "$(jq -r .digest <<<"$out")" || got=$?
  case "$got" in
    0) ;;
    1)
      echo "poll: refused request $id: its digest cannot be pulled"
      end_request "$id" refused \
        --reason "$(jq -r '"\(.digest) cannot be pulled anonymously from \(.image)"' <<<"$out")" || true
      return 1
      ;;
    *) echo "poll: GHCR did not answer for request $id; the next pass tries again" >&2; return 1 ;;
  esac
  printf '%s\n' "$out" | put "experiments/queue/$id.json"
  echo "poll: queued experiment $id"
}

# settle_experiment: an experiment.json that no experiment is running ended
# without experiment.sh closing it, as after a reboot mid-pair.
settle_experiment() {
  local f="$state/experiment.json" id
  [ -e "$f" ] || return 0
  id="$(jq -r '.id // ""' "$f")"
  if [ -n "$id" ]; then
    end_request "$id" failed --reason "the experiment stopped before it finished" --experiment "$f" \
      --records "$state/experiment/records" || return 0
  fi
  echo "poll: experiment ${id:-without an ID} stopped before it finished"
  rm -f "$f" "$state/pending-experiment.json" "$state/pending-experiment.json.rejected"
  rm -rf "${state:?}/experiment"
}

# requests: list requests/ oldest first, check up to NEW_REQUESTS_PER_PASS
# new ones, and send each queued request its position. `queued` holds their
# IDs in that order, and `listed_ok` is set once the bucket answered. A queue
# entry whose object is gone is dropped. `unchecked` is set when a request
# ends the pass neither queued nor finished: one this pass did not reach,
# could not read or check, or refused without its status going up.
queued=() listed_ok="" unchecked=""
requests() {
  local listing key id size running="" position=0 checked=0 listed=" " f
  for f in "$unsent"/*.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .json)"
    if put_status "$id" <"$f"; then
      rm -f "$f"
    fi
  done
  listing="$(limited aws s3api list-objects-v2 --bucket "$(requests_bucket)" --prefix requests/ --output json)" ||
    { echo "poll: cannot list the requests bucket; the queue waits" >&2; return 0; }
  listed_ok=1
  [ ! -e "$state/experiment.json" ] || running="$(jq -r '.id // ""' "$state/experiment.json")"
  while IFS=$'\t' read -r key size; do
    [ -n "$key" ] || continue
    # The key's match last, so BASH_REMATCH holds its ID.
    if [[ ! "$size" =~ ^[0-9]+$ ]] || [[ ! "$key" =~ ^requests/([a-z0-9][a-z0-9-]{0,99})\.json$ ]]; then
      echo "poll: deleting a requests/ object that is not requests/<id>.json" >&2
      limited aws s3api delete-object --bucket "$(requests_bucket)" --key "$key" >/dev/null || true
      continue
    fi
    id="${BASH_REMATCH[1]}"
    listed+="$id "
    [ "$id" != "$running" ] || continue
    if [ -e "$finished/$id" ]; then
      delete_request "$id" || true
      continue
    fi
    if [ ! -e "$queue/$id.json" ]; then
      if [ "$checked" -ge "$NEW_REQUESTS_PER_PASS" ]; then
        unchecked=1
        continue
      fi
      checked=$((checked + 1))
      if ! check_request "$key" "$id" "$size"; then
        [ -e "$finished/$id" ] || unchecked=1
        continue
      fi
    fi
    position=$((position + 1))
    queued+=("$id")
    send_status "$id" --state queued --position "$position" || true
  done < <(jq -r '[.Contents // [] | .[] | {k: .Key, t: .LastModified, s: .Size}] | sort_by(.t, .k) | .[]
    | "\(.k)\t\(.s)"' <<<"${listing:-"{}"}")
  for f in "$queue"/*.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .json)"
    [ "${listed#* "$id" }" != "$listed" ] || rm -f "$f" "${sent:?}/$id.json"
  done
  find "$finished" -type f -mtime +31 -delete 2>/dev/null || true
}

# --- 5. between runs --------------------------------------------------------------------

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

# experiment_ready: the oldest queued experiment may start: no earlier
# experiment's state/experiment.json is left (settle_experiment keeps it when
# its failed status cannot go up), main's set resolved this pass, nothing
# live is pending, the time is outside 02:30 to
# 03:30 UTC around the nightly run, fewer than EXPERIMENTS_PER_DAY started
# this UTC day, and no outbox flush is uploading. The caller has already
# found the box free, not held and not updating. `capped` is set, to the UTC
# day counted, when the daily count alone keeps the queue waiting.
capped=""
experiment_ready() {
  local hm n today
  [ "${#queued[@]}" -gt 0 ] || return 1
  if [ -e "$state/experiment.json" ]; then
    echo "poll: an earlier experiment is not settled yet; the queue waits"
    return 1
  fi
  [ -n "$resolved_ok" ] || { echo "poll: main's set did not resolve this pass; no experiment starts"; return 1; }
  [ ! -e "$state/pending.json" ] || return 1
  hm="${FORGE_PERF_UTC_HHMM:-$(date -u +%H%M)}"
  if [ "$hm" -ge 0230 ] && [ "$hm" -lt 0330 ]; then
    echo "poll: no experiment starts between 02:30 and 03:30 UTC"
    return 1
  fi
  today="$(date -u +%F)"
  n="$(grep -c "^$today " "$started_log" 2>/dev/null || true)"
  if [ "${n:-0}" -ge "$EXPERIMENTS_PER_DAY" ]; then
    echo "poll: $n experiments started today (UTC); the queue waits for tomorrow"
    capped="$today"
    return 1
  fi
  if ! host_ops_skipped && systemctl is-active --quiet forge-perf-outbox.service; then
    echo "poll: the outbox flush is going; the experiment starts after it"
    return 1
  fi
}

# start_experiment: plan the oldest queued experiment on this pass's main set
# and start forge-perf-experiment.service, which runs it.
start_experiment() {
  local id="${queued[0]}" set="$FORGE_PERF_RUNTIME/main-set.json" today i
  printf '%s\n' "$resolved" >"$set"
  if ! python3 "$here/experiment.py" plan --request "$queue/$id.json" --set "$set" --at "$(now)" |
    put experiment.json; then
    echo "poll: cannot plan experiment $id" >&2
    rm -f "$state/experiment.json"
    status=1
    return 0
  fi
  today="$(date -u +%F)"
  { grep "^$today " "$started_log" 2>/dev/null || true; echo "$today $id"; } | put experiments/started
  rm -f "${queue:?}/$id.json" "${sent:?}/$id.json"
  host_op systemctl start --no-block forge-perf-experiment.service
  echo "poll: started experiment $id"
  # The rest move up a place.
  queued=("${queued[@]:1}")
  for ((i = 0; i < ${#queued[@]}; i++)); do
    send_status "${queued[i]}" --state queued --position "$((i + 1))" || true
  done
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

# `busy` says what kept the pass out of its last branch, the one that only
# flushes the outbox.
active="" held="" resolved_ok="" busy=""
! run_active || active=1
if [ -z "$active" ]; then
  settle_last_run
  settle_experiment
fi

failures="$(cat "$state/poll-failures" 2>/dev/null || echo 0)"
if resolved="$(resolve)"; then
  failures=0 resolved_ok=1
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
requests

# The hold is read after resolution, which can take minutes, so a hold set
# during it still stops this pass's dispatch. run.sh checks it again under
# poll.lock.
[ ! -e "$state/hold" ] || held=1
if [ -n "$active" ]; then
  echo "poll: a run is going; the pending run starts after it"
  busy="a run is going"
elif [ -n "$held" ]; then
  echo "poll: the box is held; nothing starts (scripts/host/status.sh release)"
  flush
  busy="the box is held"
elif update; then
  busy="update.sh is starting or still going"
elif ready; then
  dispatch
  busy="a run is pending"
elif experiment_ready; then
  start_experiment
  busy="an experiment started"
else
  flush
fi
# A pass that finds update.sh finished for HEAD clears the count.
[ "$(cat "$state/updated-rev" 2>/dev/null)" != "$(git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)" ] ||
  update_failures=0
echo "$update_failures" | put update-failures

# --- 6. the heartbeat, 7. sleep -----------------------------------------------------------

# seen_keys: the distinct waker key hashes of the sets this box counts as
# seen, which are the ones want() compares a resolved set with.
seen_keys() {
  local f set
  for f in last-started.json pending.json pending.json.rejected; do
    # An empty file, or one that holds no object, has no set.
    set="$(jq -ce '.set // . | objects' "$state/$f" 2>/dev/null)" || continue
    waker_key <<<"$set"
  done | jq -Rn '[inputs] | unique'
}

# uptime_s: seconds since boot. FORGE_PERF_UPTIME_S stands in for the tests.
uptime_s() {
  if [ -n "${FORGE_PERF_UPTIME_S:-}" ]; then
    echo "$FORGE_PERF_UPTIME_S"
  else
    cut -d. -f1 /proc/uptime
  fi
}

# awake_reason: the first reason the box stays up, or nothing when it may
# sleep (docs/runner.md, "Sleeping"). The run and the hold are read again
# here: both can have changed since the pass chose its branch. NOW_S is the
# clock reading wake_time also counts from.
awake_reason() {
  local unit up of_day min="${SLEEP_MIN_AWAKE_S:-600}"
  [ "${SLEEP_WHEN_IDLE:-0}" = 1 ] || { echo "SLEEP_WHEN_IDLE is 0"; return 0; }
  [ -z "$busy" ] || { echo "$busy"; return 0; }
  ! run_active || { echo "a run is going"; return 0; }
  [ -n "$resolved_ok" ] || { echo "the set did not resolve this pass"; return 0; }
  [ -n "$listed_ok" ] || { echo "the requests bucket could not be listed this pass"; return 0; }
  [ ! -e "$state/pending.json" ] || { echo "a run is pending"; return 0; }
  [ ! -e "$state/experiment.json" ] || { echo "an experiment is not settled"; return 0; }
  [ -z "$(ls -A "$unsent" 2>/dev/null)" ] || { echo "an experiment's last status has not gone up"; return 0; }
  # The waker starts the box once for a request, so one left unchecked would
  # wait for the next wake from another cause.
  [ -z "$unchecked" ] || { echo "a request is not checked yet"; return 0; }
  # Queued experiments that wait only for tomorrow's count let the box sleep
  # until then (wake_time). A count taken before midnight UTC blocks nothing
  # after it.
  [ "${#queued[@]}" -eq 0 ] || [ "$capped" = "$(date -u +%F)" ] || { echo "an experiment is queued"; return 0; }
  [ -z "$(ls -A "$FORGE_PERF_OUTBOX" 2>/dev/null)" ] || { echo "the outbox holds files"; return 0; }
  for unit in forge-perf-outbox forge-perf-update; do
    if ! host_ops_skipped && systemctl is-active --quiet "$unit.service"; then
      echo "$unit is going"
      return 0
    fi
  done
  # 02:45 to 03:05 UTC: a box that slept now would be off, or on its way
  # down, when the nightly timer fires at 03:00.
  of_day=$((NOW_S % 86400))
  if [ "$of_day" -ge 9900 ] && [ "$of_day" -lt 11100 ]; then
    echo "the nightly run is due"
    return 0
  fi
  up="$(uptime_s 2>/dev/null)" || up=""
  if [[ ! "$up" =~ ^[0-9]+$ ]]; then
    echo "the uptime is unknown"
  elif [[ ! "$min" =~ ^[0-9]+$ ]]; then
    echo "SLEEP_MIN_AWAKE_S is not a number"
  elif [ "$up" -lt "$min" ]; then
    echo "up $up s, under SLEEP_MIN_AWAKE_S ($min)"
  elif [ -e "$state/hold" ]; then
    echo "the box is held"
  fi
}

# wake_time: when the waker starts a sleeping box again whatever else it
# sees: the next 02:55 UTC, five minutes before the nightly timer, or 00:01
# UTC tomorrow when queued experiments wait for the daily count, whichever is
# first, counted from NOW_S.
wake_time() {
  jq -rn --argjson now "$NOW_S" \
    --argjson capped "$([ -n "$capped" ] && echo true || echo false)" '
    ($now - $now % 86400) as $day | ($day + 2 * 3600 + 55 * 60) as $nightly |
    [(if $nightly > $now then $nightly else $nightly + 86400 end), (if $capped then $day + 86400 + 60 else empty end)]
    | min | todate'
}

run_id=null started=null box_state=idle wake_at=""
[ ! -e "$state/hold" ] || box_state=held
[ -z "$active" ] || box_state=running
if [ -n "$active" ] && [ -e "$state/current.json" ]; then
  run_id="$(jq -c '.run_id // null' "$state/current.json")"
  started="$(jq -c --argjson id "$run_id" 'if .run_id == $id then .time.run_started_at else null end' \
    "$state/runner.json" 2>/dev/null || echo null)"
fi
poll_failures=$((failures + update_failures))
# One clock reading for the decision and for wake_at. FORGE_PERF_UTC_EPOCH
# stands in for the clock in the tests.
NOW_S="${FORGE_PERF_UTC_EPOCH:-$(date -u +%s)}"
awake="$(awake_reason)"
if [ -z "$awake" ]; then
  box_state=asleep poll_failures=0 wake_at="$(wake_time)"
fi
jq -n --arg box "$FORGE_PERF_BOX_ID" --arg at "$(now)" --arg sha "$(git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)" \
  --arg state "$box_state" \
  --argjson run_id "$run_id" --argjson started "$started" --argjson failures "$poll_failures" \
  --argjson kind "$(jq -c '.kind // null' "$state/pending.json" 2>/dev/null || echo null)" \
  --argjson queued "${#queued[@]}" --argjson seen "$(seen_keys)" --arg wake "$wake_at" \
  '{box: $box, at: $at, forge_perf_sha: $sha, state: $state, run_id: $run_id, run_started_at: $started,
    pending_kind: $kind, poll_failures: $failures, experiments_queued: $queued, seen_keys: $seen,
    wake_at: (if $wake == "" then null else $wake end)}' >"$FORGE_PERF_RUNTIME/heartbeat.json"
if ! limited aws s3api put-object --bucket "$bucket" --key "published/$FORGE_PERF_BOX_ID/heartbeat.json" \
  --body "$FORGE_PERF_RUNTIME/heartbeat.json" --content-type application/json >/dev/null; then
  echo "poll: the heartbeat did not go up" >&2
  status=1
  # The waker starts only a box whose heartbeat says asleep.
  [ -n "$awake" ] || awake="the heartbeat did not go up"
fi
# The upload can take a minute, and status.sh hold does not wait for the
# pass, so the hold and the run are read once more. The asleep heartbeat that
# went up is replaced by the next pass.
if [ -z "$awake" ]; then
  if [ -e "$state/hold" ]; then
    awake="the box is held"
  elif run_active; then
    awake="a run is going"
  fi
fi
if [ -n "$awake" ]; then
  echo "poll: staying up: $awake"
else
  echo "poll: idle; asleep until $wake_at"
  if ! host_op systemctl poweroff; then
    echo "poll: systemctl poweroff failed; the box stays up" >&2
    status=1
  fi
fi
exit "$status"
