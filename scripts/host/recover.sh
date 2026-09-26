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
# The tarball leaves out *.env files and provider/, and drops every line that
# names access_key_id or secret_access_key, which `piri init` prints. Each
# step skips what an earlier attempt finished, so the unit can be restarted.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

runner_init
take_run_lock
current="$FORGE_PERF_STATE_DIR/current.json"

flush() {
  "$here/outbox.sh" flush || echo "recover: the outbox keeps files for the next poll" >&2
}

if [ ! -e "$current" ]; then
  step "no interrupted run"
  flush
  exit 0
fi

{ read -r run_id; read -r phase; read -r run_dir; } < <(python3 - "$current" "$FORGE_PERF_WORK/run" <<'PY'
import json, re, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
run_id = c.get("run_id") or ""
if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", run_id):
    sys.exit("current.json has no usable run_id")
print(run_id)
print(c.get("phase") or "unknown")
print(c.get("run_dir") or sys.argv[2])
PY
)
[ -n "${run_id:-}" ] || die "cannot read $current"
step "recovering $run_id (phase $phase)"
case "$phase" in
  recorded | uploaded | wiping) needs_record=false ;;
  *) needs_record=true ;;
esac
mkdir -p "$FORGE_PERF_OUTBOX"
raw="$FORGE_PERF_OUTBOX/$run_id.raw.tar.zst"
record="$FORGE_PERF_OUTBOX/$run_id.json"

step "stop containers"
ids="$(stack_containers)"
# shellcheck disable=SC2086 # container IDs
[ -z "$ids" ] || docker stop -t 30 $ids >/dev/null

raw_missing=0
if [ "$needs_record" = true ] && [ ! -e "$raw" ]; then
  step "collect the raw tarball"
  stage="$FORGE_PERF_WORK/recover-raw"
  rm -rf "$stage"
  mkdir -p "$stage/run" "$stage/logs"
  if [ -d "$run_dir" ]; then
    tar -C "$run_dir" --exclude '*.env' --exclude provider -cf - . | tar -C "$stage/run" -xf -
  fi
  for id in $ids; do
    name="$(docker inspect --format '{{.Name}}' "$id")"
    docker logs --timestamps "$id" >"$stage/logs/${name#/}.log" 2>&1 || true
  done
  while IFS= read -r -d '' f; do
    LC_ALL=C grep -a -viE 'access_key_id|secret_access_key' "$f" >"$f.scrub" || true
    mv "$f.scrub" "$f"
  done < <(find "$stage" -type f -print0)
  creds="$FORGE_PERF_PIRI_S3_CREDENTIALS"
  if [ -r "$creds" ] && (
    # shellcheck disable=SC1090
    . "$creds"
    for secret in "${FORGE_PERF_PIRI_S3_KEY_ID:-}" "${FORGE_PERF_PIRI_S3_SECRET:-}"; do
      [ -z "$secret" ] || ! grep -rqF -e "$secret" "$stage" || exit 0
    done
    exit 1
  ); then
    echo "recover: a piri credential is still in the collected files; no raw tarball" >&2
    raw_missing=1
  else
    tar -C "$stage" -cf - . | zstd -q -f -o "$raw.tmp"
    mv "$raw.tmp" "$raw"
  fi
fi

if [ "$needs_record" = true ] && [ ! -e "$record" ]; then
  step "write the no_data record"
  amended="$FORGE_PERF_STATE_DIR/recover-runner.json"
  [ -e "$amended" ] || [ -r "$run_dir/runner.json" ] || die "no runner.json for $run_id"
  [ -e "$amended" ] || python3 - "$run_dir/runner.json" "$amended" "$raw_missing" <<'PY'
import datetime, json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
if "drill_interrupted" not in r["reasons"]:
    r["reasons"].append("drill_interrupted")
if not r["time"].get("run_finished_at"):
    r["time"]["run_finished_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if sys.argv[3] == "1":
    r["raw_missing"] = True
json.dump(r, open(sys.argv[2], "w", encoding="utf-8"), indent=1)
PY
  denylist="${FORGE_PERF_DENYLIST_FILE:-$FORGE_PERF_RUNTIME/secrets/denylist.regex}"
  if [ ! -r "$denylist" ]; then
    host_ops_skipped && die "set FORGE_PERF_DENYLIST_FILE to the denylist pattern file"
    mkdir -p "$(dirname "$denylist")"
    (umask 077 && aws ssm get-parameter --with-decryption --name "${FORGE_PERF_DENYLIST_PARAM:-/forge-perf/denylist}" \
      --query Parameter.Value --output text >"$denylist")
  fi
  status=0
  python3 "$here/record.py" build --runner "$amended" --denylist "$denylist" --out "$record" || status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ] || die "record.py wrote no record (exit $status)"
fi

step "wipe"
FORGE_PERF_LOCK_HELD=1 "$here/wipe.sh"
rm -f "$current" "$FORGE_PERF_STATE_DIR/recover-runner.json"
flush
step "recovered $run_id"
