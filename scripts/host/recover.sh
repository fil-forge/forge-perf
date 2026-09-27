#!/usr/bin/env bash
# Close out a run that a reboot interrupted, then flush the outbox.
#
#   recover.sh     run by forge-perf-recover.service at boot, before any poll
#
# Reads $FORGE_PERF_STATE_DIR/current.json ({run_id, phase, run_dir}). With no
# current.json it only flushes the outbox. Otherwise, in order: stop every
# container Docker restarted; for a run whose phase comes before `recorded`
# (preflight, boot, drill, or a phase it does not know), collect each
# container's `docker logs --timestamps` and the run directory into the raw
# tarball and write a no_data record with reason drill_interrupted to the
# outbox; remove the containers, empty the buckets and wipe (wipe.sh); remove
# current.json; flush the outbox. A later phase already put its files in the
# outbox, so recovery adds none.
#
# The record is best effort and the wipe is not. When no record can be built
# (no usable run_id, no runner.json, or record.py writes nothing), recovery
# says why, wipes, and moves current.json to current.json.failed-<time> so the
# next boot formats the NVMe. An SSM read that fails stops recovery with
# current.json kept, so a restart or the next boot retries it; after
# $FORGE_PERF_RECOVER_ATTEMPTS attempts (default 3) recovery goes on without
# that input. A failed wipe also keeps current.json until the last attempt,
# which moves it aside, leaves $FORGE_PERF_RUNTIME/recover-failed and exits 4,
# a status the unit does not restart on. While that marker exists every later
# start exits 4 as well, so no poll or run starts on the box until a reboot
# clears /run.
# A collection step that fails (a full disk, a Docker error) costs the raw
# tarball, never the wipe. runner.json comes from the run directory, or from
# $FORGE_PERF_STATE_DIR/runner.json when a stop/start left the NVMe blank.
#
# The tarball leaves out *.env files and provider/, and drops every line that
# names access_key_id or secret_access_key, which `piri init` prints. It is not
# written while piri's key ID, piri's secret or the harness credential appears
# in the collected files, or while those values cannot be read. Each step skips
# what an earlier attempt finished, so the unit can be restarted.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

runner_init
take_run_lock
failed_marker="$FORGE_PERF_RUNTIME/recover-failed"
if [ -e "$failed_marker" ]; then
  echo "ERROR: an earlier recovery could not wipe; reboot, or remove $failed_marker after a manual wipe" >&2
  exit 4
fi
current="$FORGE_PERF_STATE_DIR/current.json"
attempts="$FORGE_PERF_STATE_DIR/recover-attempts"
amended="$FORGE_PERF_STATE_DIR/recover-runner.json"
ssm_path="${FORGE_PERF_SSM_PATH:-/forge-perf}"

flush() {
  "$here/outbox.sh" flush || echo "recover: the outbox keeps files for the next poll" >&2
}

if [ ! -e "$current" ]; then
  step "no interrupted run"
  rm -f "$attempts" "$amended"
  flush
  exit 0
fi

attempt=$(($(cat "$attempts" 2>/dev/null || echo 0) + 1))
echo "$attempt" >"$attempts"
max_attempts="${FORGE_PERF_RECOVER_ATTEMPTS:-3}"

# An input that a later attempt may read (an SSM parameter). Stop and keep
# current.json while attempts remain; on the last one, go on without it.
transient() {
  [ "$attempt" -ge "$max_attempts" ] || die "$1; attempt $attempt of $max_attempts, current.json kept for a retry"
  echo "recover: $1; attempt $attempt of $max_attempts, going on without it" >&2
}

# Write piri's key ID and secret and the harness credential to $1, one string
# per line. piri's pair comes from its credentials file while /run still holds
# it, otherwise from SSM. Fails when a value cannot be read. Every read is
# checked explicitly, because callers run this as an `if` condition, where
# bash ignores set -e.
read_credentials() (
  umask 077
  creds="$FORGE_PERF_PIRI_S3_CREDENTIALS"
  id="" secret=""
  if [ -r "$creds" ]; then
    # shellcheck disable=SC1090
    . "$creds" || exit 1
    id="${FORGE_PERF_PIRI_S3_KEY_ID:-}" secret="${FORGE_PERF_PIRI_S3_SECRET:-}"
  elif host_ops_skipped; then
    echo "recover: $creds is missing" >&2
    exit 1
  else
    id="$(ssm_value "${FORGE_PERF_PIRI_KEY_ID_PARAM:-$ssm_path/piri-s3-access-key-id}")" || exit 1
    secret="$(ssm_value "${FORGE_PERF_PIRI_SECRET_PARAM:-$ssm_path/piri-s3-secret-access-key}")" || exit 1
  fi
  # Strings shorter than 8 characters are not checked against (see below).
  [ "${#id}" -ge 8 ] && [ "${#secret}" -ge 8 ] || { echo "recover: piri's key ID or secret is empty" >&2; exit 1; }
  printf '%s\n' "$id" "$secret" >"$1.all" || exit 1
  if ! host_ops_skipped; then
    # The harness credential's parameter may not exist yet; any other error fails.
    ssm_value "${FORGE_PERF_HARNESS_CREDENTIAL_PARAM:-$ssm_path/harness-deploy-key}" >>"$1.all" 2>"$1.err" ||
      grep -q ParameterNotFound "$1.err" || exit 1
    # The GitHub App's private key, from its JSON parameter.
    app="$(ssm_value "${FORGE_PERF_HARNESS_APP_PARAM:-$ssm_path/harness-app}" 2>"$1.err")" ||
      grep -q ParameterNotFound "$1.err" || exit 1
    [ -z "$app" ] || jq -r '.private_key // empty' <<<"$app" >>"$1.all" || exit 1
  fi
  # The installation token the run minted, while /run still holds it.
  token="$FORGE_PERF_RUNTIME/secrets/harness-token"
  [ ! -r "$token" ] || cat "$token" >>"$1.all" || exit 1
  # Keep strings of 8 or more characters, so no blank line matches everything.
  awk '{ gsub(/^[ \t]+|[ \t\r]+$/, "") } length($0) >= 8' "$1.all" >"$1" || exit 1
  rm -f "$1.all" "$1.err"
)

run_id="" phase=unknown run_dir="" no_record=""
if parsed="$(python3 - "$current" "$FORGE_PERF_WORK/run" 2>&1 <<'PY'
import json, re, sys
try:
    c = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError) as e:
    sys.exit(f"current.json is not JSON ({type(e).__name__})")
run_id = c.get("run_id") if isinstance(c, dict) else None
if not isinstance(run_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", run_id):
    sys.exit("current.json has no usable run_id")
print(run_id)
print(c.get("phase") or "unknown")
print(c.get("run_dir") or sys.argv[2])
PY
)"; then
  { read -r run_id; read -r phase; read -r run_dir; } <<<"$parsed"
else
  no_record="$parsed"
  echo "recover: $no_record; wiping without a record" >&2
fi
step "recovering ${run_id:-an unnamed run} (phase $phase, attempt $attempt)"
needs_record=false
if [ -n "$run_id" ]; then
  case "$phase" in
    recorded | uploaded | wiping) ;;
    *) needs_record=true ;;
  esac
fi
mkdir -p "$FORGE_PERF_OUTBOX"
raw="$FORGE_PERF_OUTBOX/$run_id.raw.tar.zst"
record="$FORGE_PERF_OUTBOX/$run_id.json"
forbid="$FORGE_PERF_RUNTIME/secrets/recover-forbid"

step "stop containers"
ids="$(stack_containers)"
# shellcheck disable=SC2086 # container IDs
[ -z "$ids" ] || docker stop -t 30 $ids >/dev/null ||
  echo "recover: docker stop failed; the wipe removes the containers" >&2

have_forbid=false
if [ "$needs_record" = true ]; then
  mkdir -p "$(dirname "$forbid")"
  if read_credentials "$forbid"; then
    have_forbid=true
  else
    transient "cannot read piri's credentials or the harness credential"
  fi
fi

raw_missing=0
if [ "$needs_record" = true ] && [ ! -e "$raw" ]; then
  step "collect the raw tarball"
  [ "$have_forbid" = true ] || forbid=/dev/null
  status=0
  "$here/collect.sh" "$raw" "$forbid" "run=$run_dir" "perf-runs=$FORGE_PERF_WORK/smelt/generated/perf-runs" ||
    status=$?
  case "$status" in
    0) ;;
    3) raw_missing=1 ;;
    *)
      echo "recover: collecting the raw tarball failed; the record carries raw_missing" >&2
      raw_missing=1
      ;;
  esac
fi

if [ "$needs_record" = true ] && [ ! -e "$record" ]; then
  step "write the no_data record"
  runner="$run_dir/runner.json"
  [ -e "$runner" ] || runner="$FORGE_PERF_STATE_DIR/runner.json"
  # A runner copy left by another run's failed recovery is not this run's.
  if [ -e "$amended" ] && ! python3 -c 'import json, sys
sys.exit(json.load(open(sys.argv[1], encoding="utf-8")).get("run_id") != sys.argv[2])' "$amended" "$run_id" 2>/dev/null; then
    rm -f "$amended"
  fi
  if [ ! -e "$amended" ] && ! python3 - "$runner" "$amended" "$raw_missing" <<'PY'; then
import datetime, json, sys
try:
    r = json.load(open(sys.argv[1], encoding="utf-8"))
    if "drill_interrupted" not in r["reasons"]:
        r["reasons"].append("drill_interrupted")
    if not r["time"].get("run_finished_at"):
        r["time"]["run_finished_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
    sys.exit(f"recover: no usable runner.json ({type(e).__name__})")
if sys.argv[3] == "1":
    r["raw_missing"] = True
json.dump(r, open(sys.argv[2], "w", encoding="utf-8"), indent=1)
PY
    no_record="no usable runner.json for $run_id"
  fi
  denylist="${FORGE_PERF_DENYLIST_FILE:-$FORGE_PERF_RUNTIME/secrets/denylist.regex}"
  if [ -z "$no_record" ] && [ ! -s "$denylist" ]; then
    host_ops_skipped && die "set FORGE_PERF_DENYLIST_FILE to the denylist pattern file"
    mkdir -p "$(dirname "$denylist")"
    if (umask 077 && ssm_value "${FORGE_PERF_DENYLIST_PARAM:-$ssm_path/denylist}" >"$denylist.tmp"); then
      mv "$denylist.tmp" "$denylist"
    else
      rm -f "$denylist.tmp"
      transient "cannot read the denylist from SSM"
      no_record="no denylist"
    fi
  fi
  if [ -z "$no_record" ]; then
    set -- --runner "$amended" --denylist "$denylist" --out "$record"
    [ "$have_forbid" != true ] || set -- "$@" --forbid "$forbid"
    status=0
    python3 "$here/record.py" build "$@" || status=$?
    [ "$status" -eq 0 ] || [ "$status" -eq 3 ] || no_record="record.py wrote no record (exit $status)"
  fi
  [ -z "$no_record" ] || echo "recover: $no_record; wiping without a record" >&2
fi

set_aside() {
  failed="$current.failed-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$current" "$failed"
  rm -f "$amended" "$attempts" "$FORGE_PERF_STATE_DIR/runner.json"
  echo "recover: kept the state as $failed" >&2
}

step "wipe"
if ! FORGE_PERF_LOCK_HELD=1 "$here/wipe.sh"; then
  # On the last attempt, move current.json aside so the next boot formats the
  # NVMe instead of failing the same way. Exit 4 is in the unit's
  # RestartPreventExitStatus=, so the unit stays failed until then. The marker
  # makes every later start fail the same way until a reboot clears /run, so
  # the poll and run units, which require this one, do not start either.
  [ "$attempt" -ge "$max_attempts" ] || die "the wipe failed; attempt $attempt of $max_attempts, current.json kept for a retry"
  set_aside
  mkdir -p "$FORGE_PERF_RUNTIME" && : >"$failed_marker"
  echo "ERROR: the wipe failed on the last attempt" >&2
  exit 4
fi
if [ -n "$no_record" ]; then
  set_aside
else
  rm -f "$current" "$amended" "$attempts" "$FORGE_PERF_STATE_DIR/runner.json"
fi
flush
step "recovered ${run_id:-an unnamed run}"
