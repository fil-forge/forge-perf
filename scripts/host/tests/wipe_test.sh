#!/usr/bin/env bash
# Behavior of wipe.sh, recover.sh and outbox.sh against a stubbed docker and
# aws. The docker stub keeps containers, volumes, forge-network and images as
# files, so each test sets up a dirty box and checks what is left afterwards.
# The box-mode tests stub fstrim, sysctl, flock and `id -u` as well.
set -euo pipefail

host="$(cd "$(dirname "$0")/.." && pwd -P)"
repo="$(cd "$host/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/wipe-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export D="$work/docker"
mkdir -p "$work/bin"
unset INVOCATION_ID FORGE_PERF_HOST_OPS FORGE_PERF_LOCK_HELD
export PYTHONDONTWRITEBYTECODE=1

cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "docker $*" >>"$D/log"
filter() { while [ $# -gt 0 ]; do [ "$1" != --filter ] || { echo "$2"; return; }; shift; done; }
drop() { grep -v "^$1 " "$2" >"$2.new" || true; mv "$2.new" "$2"; }
case "$1 ${2:-}" in
  "ps -aq")
    f="$(filter "$@")"
    while read -r id name proj; do
      case "$f" in
        "") echo "$id" ;;
        label=*) [ "$proj" != "${f##*=}" ] || echo "$id" ;;
        name=^*) case "$name" in "${f#name=^}"*) echo "$id" ;; esac ;;
      esac
    done <"$D/containers" ;;
  "rm -f"*) shift 2; for id; do drop "$id" "$D/containers"; done ;;
  "stop -t") [ ! -e "$D/stop-fails" ] || { echo "docker stop: daemon busy" >&2; exit 1; } ;;
  "logs --timestamps") echo "2026-10-01T20:01:00Z up $3"; echo "2026-10-01T20:01:01Z access_key_id: AKIAFAKE" ;;
  "inspect --format") awk -v id="$4" '$1 == id { print "/" $2 }' "$D/containers" ;;
  "volume ls")
    f="$(filter "$@")"
    while read -r name proj; do
      [ -n "$f" ] && [ "$proj" != "${f##*=}" ] || echo "$name"
    done <"$D/volumes" ;;
  "volume rm") shift 2; for v; do grep -qx "$v" "$D/stuck" 2>/dev/null || drop "$v" "$D/volumes"; done ;;
  "network inspect") [ -e "$D/network" ] ;;
  "network rm") rm "$D/network" ;;
  "network prune") echo "$*" >>"$D/pruned" ;;
  "image ls") awk '{ print $1 }' "$D/images" ;;
  "image inspect") awk -v id="${!#}" '$1 == id && $2 != "-" { print $2 }' "$D/images" ;;
  "image rm") drop "${!#}" "$D/images" ;;
  *) echo "docker stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$D/aws.log"
args=" $* "
case "$args" in
  *" s3api head-bucket "*) ! grep -qF -- "${args##*--bucket }" "$D/missing" 2>/dev/null ;;
  *" list-multipart-uploads "*allocations*) printf 'big.bin\tUPLOAD1\n' ;;
  *" list-multipart-uploads "*) echo None ;;
  *" s3 cp "*) [ ! -e "$D/s3-down" ] ;;
  *" ssm get-parameter "*)
    [ ! -e "$D/ssm-down" ] || { echo "ssm unreachable" >&2; exit 255; }
    if [ -s "$D/ssm-fail" ] && grep -qF -- "$(cat "$D/ssm-fail")" <<<"$args"; then
      echo "ThrottlingException" >&2; exit 255
    fi
    case "$args" in
      *piri-s3-access-key-id*) echo AKIAFAKE ;;
      *piri-s3-secret-access-key*) echo fake-secret ;;
      *harness-deploy-key*)
        [ -e "$D/harness" ] || { echo "An error occurred (ParameterNotFound)" >&2; exit 254; }
        cat "$D/harness" ;;
      *denylist*) echo FORBIDDEN-WORD ;;
    esac ;;
  *" put-object "*)
    [ ! -e "$D/s3-down" ] || exit 1
    [ ! -e "$D/uploaded" ] ||
      { echo "An error occurred (PreconditionFailed) when calling the PutObject operation" >&2; exit 254; } ;;
esac
STUB
# shellcheck disable=SC2016 # the stubs expand their own arguments
for tool in make fstrim sysctl sync flock systemctl; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$D/host.log"\n' "$tool" >"$work/bin/$tool"
done
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[ "$1" = -u ] && echo 0 || /usr/bin/id "$@"\n' >"$work/bin/id"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

netshoot="$(grep -v "^#" "$repo/config/images.lock" | grep -oE "sha256:[0-9a-f]{64}" | head -1)"
tracked=sha256:1111111111111111111111111111111111111111111111111111111111111111

# A box in the middle of a run: the smelt stack, a netem sidecar, one other
# project, volumes, forge-network, images, a work tree and secrets.
setup() {
  rm -rf "$D" "$work/box"
  mkdir -p "$D" "$work/box/"{state,nvme/work/run,outbox,run/secrets,run/aws}
  printf '%s\n' "c1 smelt-ingot-1 smelt" "c2 smelt-piri-0-1 smelt" "c3 forge-perf-iperf-1 -" "c4 laptop-db other" >"$D/containers"
  printf '%s\n' "smelt_ingot-data smelt" "smelt_minio-data smelt" "laptop-data other" >"$D/volumes"
  touch "$D/network"
  printf '%s\n' "i1 nicolaka/netshoot@$netshoot" "i2 ghcr.io/fil-forge/ingot@$tracked" \
    "i3 ghcr.io/fil-forge/ingot@sha256:2222" "i4 laptop/app@sha256:3333" "i5 postgres@sha256:4444" >"$D/images"
  echo "ghcr.io/fil-forge/ingot:main@$tracked" >"$work/box/state/images.pinned"
  printf '%s\n' FORGE_PERF_PIRI_S3_KEY_ID=AKIAFAKE FORGE_PERF_PIRI_S3_SECRET=fake-secret >"$work/box/run/secrets/piri-s3.env"
  echo x >"$work/box/nvme/work/run/drill.out"
  printf '%s\n' FORGE_PERF_BOX_ID=main FORGE_PERF_PIRI_BUCKET_PREFIX=pfx- FORGE_PERF_RESULTS_BUCKET=results \
    >"$work/box/box.conf"
  echo 'FORBIDDEN-WORD' >"$work/box/denylist"
}
export FORGE_PERF_BOX_CONF="$work/box/box.conf" FORGE_PERF_CHECKOUT="$repo" \
  FORGE_PERF_STATE_DIR="$work/box/state" FORGE_PERF_NVME_MOUNT="$work/box/nvme" \
  FORGE_PERF_OUTBOX="$work/box/outbox" FORGE_PERF_RUNTIME="$work/box/run" \
  FORGE_PERF_DENYLIST_FILE="$work/box/denylist" FORGE_PERF_IMDS_URL=http://127.0.0.1:9

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$2" "$1" || fail "$1 lacks: $2"; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 has: $2"; }
count() { local n; n="$(grep -c . "$1" || true)"; [ "$n" = "$2" ] || fail "$1 has $n lines, want $2"; }

# --- wipe on the box ------------------------------------------------------------
setup
"$host/wipe.sh" >"$work/out" 2>&1 || { cat "$work/out"; fail "wipe exited non-zero"; }
count "$D/containers" 0
count "$D/volumes" 0
[ ! -e "$D/network" ] || fail "forge-network survived"
for s in allocations acceptances claims receipts pdp consolidation; do
  has "$D/aws.log" "--endpoint-url https://s3.us-east-2.amazonaws.com --region us-east-2 s3 rm s3://pfx-$s --recursive"
done
has "$D/aws.log" "abort-multipart-upload --bucket pfx-allocations --key big.bin --upload-id UPLOAD1"
[ -z "$(ls -A "$work/box/nvme/work")" ] || fail "work tree survived"
[ ! -e "$work/box/run/secrets" ] && [ ! -e "$work/box/run/aws" ] || fail "secrets survived"
has "$D/host.log" "fstrim $work/box/nvme"
has "$D/host.log" "sysctl -q vm.drop_caches=3"
has "$D/host.log" "flock 9"
lacks "$D/host.log" "systemctl"
[ "$(awk '{ print $1 }' "$D/images" | tr '\n' ' ')" = "i1 i2 " ] || fail "images left: $(cat "$D/images")"
has "$D/pruned" "network prune -f"
echo "ok: the box wipe leaves no container, volume, network, work tree or unpinned image, and keeps Docker up"

: >"$D/log"
"$host/wipe.sh" --if-dirty >"$work/out" 2>&1
has "$work/out" "clean; nothing to do"
lacks "$D/log" "rm -f"
"$host/wipe.sh" >"$work/out" 2>&1 || fail "a second full wipe failed"
echo "ok: a second wipe is a no-op"

FORGE_PERF_LOCK_HELD=1 "$host/wipe.sh" >/dev/null 2>&1 || fail "wipe with the lock held failed"
: >"$D/host.log"
setup
FORGE_PERF_LOCK_HELD=1 "$host/wipe.sh" >/dev/null 2>&1
lacks "$D/host.log" "flock"
echo "ok: FORGE_PERF_LOCK_HELD skips the lock"

setup
echo smelt_minio-data >"$D/stuck"
if "$host/wipe.sh" >"$work/out" 2>&1; then fail "wipe passed with a volume left"; fi
has "$work/out" "remain after the wipe: smelt_minio-data"
echo "ok: a volume that survives fails the wipe"

setup
rm "$work/box/state/images.pinned"
"$host/wipe.sh" >/dev/null 2>&1 || fail "wipe without images.pinned failed"
[ "$(awk '{ print $1 }' "$D/images" | tr '\n' ' ')" = "i1 " ] || fail "images left: $(cat "$D/images")"
echo "ok: without a run's pinned set only images.lock's images stay"

# --- wipe in skip mode -------------------------------------------------------------
setup
: >"$D/host.log"
FORGE_PERF_HOST_OPS=skip "$host/wipe.sh" >"$work/out" 2>&1 || { cat "$work/out"; fail "local wipe failed"; }
[ "$(cat "$D/containers")" = "c4 laptop-db other" ] || fail "local wipe touched other containers"
[ "$(cat "$D/volumes")" = "laptop-data other" ] || fail "local wipe touched other volumes"
[ "$(awk '{ print $1 }' "$D/images" | tr '\n' ' ')" = "i1 i2 i4 i5 " ] || fail "local images left: $(cat "$D/images")"
has "$work/out" "host-op skipped: fstrim"
has "$work/out" "host-op skipped: sysctl -q vm.drop_caches=3"
lacks "$D/host.log" "fstrim"
lacks "$D/host.log" "sysctl"
has "$D/pruned" "network prune -f --filter label=com.docker.compose.project=smelt"
echo "ok: skip mode wipes only the stack and logs the host operations"

setup
cat >>"$work/box/box.conf" <<EOF
FORGE_PERF_PIRI_S3_ENDPOINT=minio:9000
FORGE_PERF_PIRI_S3_INSECURE=true
FORGE_PERF_PIRI_S3_HOST_URL=http://localhost:9000
FORGE_PERF_PIRI_S3_HOST_AUTH=key
EOF
FORGE_PERF_HOST_OPS=skip "$host/wipe.sh" >/dev/null 2>&1
has "$D/aws.log" "--endpoint-url http://localhost:9000 --region us-east-2 s3 rm s3://pfx-pdp"
echo "ok: the piri endpoint and credentials come from config"

# --- recover ------------------------------------------------------------------------
setup
cp "$host/fixtures/stack-boot-failed/runner.json" "$work/box/nvme/work/run/runner.json"
mkdir -p "$work/box/nvme/work/run/provider"
echo "secret" >"$work/box/nvme/work/run/provider/key"
echo "PIRI=1" >"$work/box/nvme/work/run/drill.env"
echo '{"run_id": "main-20261001t200000z", "phase": "drill"}' >"$work/box/state/current.json"
touch "$D/s3-down"
if "$host/recover.sh" >"$work/out" 2>&1; then :; else cat "$work/out"; fail "recover failed"; fi
rec="$work/box/outbox/main-20261001t200000z.json"
raw="$work/box/outbox/main-20261001t200000z.raw.tar.zst"
[ -s "$rec" ] && [ -s "$raw" ] || fail "outbox lacks the record or tarball"
python3 - "$rec" <<'PY' || fail "record is not no_data/drill_interrupted"
import json, sys
o = json.load(open(sys.argv[1]))["outcome"]
assert o["class"] == "no_data" and "drill_interrupted" in o["reasons"] and "record_build_failed" not in o["reasons"], o
PY
zstd -dc "$raw" | tar -tf - >"$work/list"
has "$work/list" "run/drill.out"
has "$work/list" "logs/smelt-ingot-1.log"
lacks "$work/list" "provider"
lacks "$work/list" "drill.env"
zstd -dc "$raw" | tar -xOf - ./logs/smelt-piri-0-1.log >"$work/log"
has "$work/log" "up c2"
lacks "$work/log" "AKIAFAKE"
[ ! -e "$work/box/state/current.json" ] || fail "current.json survived"
count "$D/containers" 0
echo "ok: recovery in phase drill writes a no_data record and a scrubbed raw tarball, then wipes"

rm -f "$D/s3-down"
touch "$D/uploaded"
: >"$D/aws.log"
"$host/outbox.sh" flush >"$work/out" 2>&1 || { cat "$work/out"; fail "flush failed"; }
[ -z "$(ls -A "$work/box/outbox")" ] || fail "outbox not empty"
has "$work/out" "record main-20261001t200000z was already uploaded"
[ "$(grep -n 's3 cp' "$D/aws.log" | cut -d: -f1)" -lt "$(grep -n 'put-object' "$D/aws.log" | cut -d: -f1)" ] ||
  fail "record went up before raw"
has "$D/aws.log" "s3://results/raw/main/main-20261001t200000z/raw.tar.zst --checksum-algorithm SHA256"
has "$D/aws.log" "--key published/main/main-20261001t200000z.json"
has "$D/aws.log" "--if-none-match *"
echo "ok: the flush uploads raw before record and treats a 412 as done"

setup
cp "$host/fixtures/stack-boot-failed/runner.json" "$work/box/nvme/work/run/runner.json"
echo '{"run_id": "main-20261001t200000z", "phase": "uploaded"}' >"$work/box/state/current.json"
"$host/recover.sh" >"$work/out" 2>&1 || { cat "$work/out"; fail "recover (uploaded) failed"; }
[ -z "$(ls -A "$work/box/outbox")" ] || fail "recovery in phase uploaded wrote to the outbox"
[ ! -e "$work/box/state/current.json" ] && [ "$(grep -c . "$D/containers" || true)" = 0 ] || fail "not wiped"
echo "ok: recovery in phase uploaded writes nothing and wipes"

setup
"$host/recover.sh" >"$work/out" 2>&1
has "$work/out" "no interrupted run"
[ "$(grep -c . "$D/containers")" = 4 ] || fail "recovery without current.json touched the stack"
echo "ok: without current.json recovery only flushes the outbox"

# --- recovery failure paths ---------------------------------------------------------
current="$work/box/state/current.json"
recover_ok() { "$host/recover.sh" >"$work/out" 2>&1 || { cat "$work/out"; fail "recover exited non-zero: $1"; }; }
wiped() {
  count "$D/containers" 0
  [ ! -e "$current" ] || fail "current.json kept after: $1"
  ls "$current".failed-* >/dev/null 2>&1 || fail "current.json not moved aside after: $1"
}

setup
echo '{"run_id": "main-20261001t200000z", "phase": "preflight"}' >"$current"
touch "$D/s3-down"
recover_ok "no runner.json"
has "$work/out" "no usable runner.json"
wiped "no runner.json"
[ -s "$work/box/outbox/main-20261001t200000z.raw.tar.zst" ] || fail "raw tarball not kept"
[ ! -e "$work/box/outbox/main-20261001t200000z.json" ] || fail "a record appeared"
echo "ok: without runner.json recovery keeps the raw tarball, wipes and moves current.json aside"

setup
python3 - "$host/fixtures/stack-boot-failed/runner.json" "$work/box/nvme/work/run/runner.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
del r["settings"]
json.dump(r, open(sys.argv[2], "w"))
PY
echo '{"run_id": "main-20261001t200000z", "phase": "drill"}' >"$current"
recover_ok "record.py fails"
has "$work/out" "record.py wrote no record"
wiped "record.py fails"
echo "ok: a record that cannot be built does not stop the wipe"

for bad in '{"run_id": "../x", "phase": "drill"}' 'not json'; do
  setup
  echo "$bad" >"$current"
  recover_ok "current.json $bad"
  wiped "current.json $bad"
  [ -z "$(ls -A "$work/box/outbox")" ] || fail "outbox written for an unnamed run"
done
echo "ok: an unreadable current.json is wiped and moved aside"

setup
cp "$host/fixtures/stack-boot-failed/runner.json" "$work/box/nvme/work/run/runner.json"
echo '{"run_id": "main-20261001t200000z", "phase": "drill"}' >"$current"
touch "$D/ssm-down"
if FORGE_PERF_DENYLIST_FILE='' "$host/recover.sh" >"$work/out" 2>&1; then fail "recover passed with SSM down"; fi
has "$work/out" "attempt 1 of 3, current.json kept"
[ -e "$current" ] && [ "$(grep -c . "$D/containers")" = 4 ] || fail "attempt 1 wiped without its record"
[ ! -e "$work/box/run/secrets/denylist.regex" ] || fail "a failed fetch left a denylist file"
rm "$D/ssm-down" "$work/box/run/secrets/piri-s3.env"
touch "$D/s3-down"
FORGE_PERF_DENYLIST_FILE='' "$host/recover.sh" >"$work/out" 2>&1 || { cat "$work/out"; fail "attempt 2 failed"; }
[ -s "$work/box/outbox/main-20261001t200000z.json" ] || fail "attempt 2 wrote no record"
has "$D/aws.log" "ssm get-parameter --with-decryption --name /forge-perf/piri-s3-secret-access-key"
[ ! -e "$current" ] || fail "current.json kept after attempt 2"
if ls "$current".failed-* >/dev/null 2>&1; then fail "current.json moved aside after a full recovery"; fi
[ ! -e "$work/box/state/recover-attempts" ] || fail "attempt count kept"
echo "ok: a failed SSM read keeps current.json, and the restart reads the denylist and piri's pair and finishes"

setup
cp "$host/fixtures/stack-boot-failed/runner.json" "$work/box/nvme/work/run/runner.json"
echo '{"run_id": "main-20261001t200000z", "phase": "drill"}' >"$current"
rm "$work/box/run/secrets/piri-s3.env"
touch "$D/ssm-down"
FORGE_PERF_RECOVER_ATTEMPTS=1 FORGE_PERF_DENYLIST_FILE='' "$host/recover.sh" >"$work/out" 2>&1 ||
  { cat "$work/out"; fail "last attempt failed"; }
wiped "the last attempt"
[ -z "$(ls -A "$work/box/outbox")" ] || fail "outbox written without credentials or denylist"
echo "ok: the last attempt wipes without the inputs SSM could not supply"

# A credential in a form the line filter misses, with /run empty as after a reboot.
for leak in piri harness; do
  setup
  cp "$host/fixtures/stack-boot-failed/runner.json" "$work/box/nvme/work/run/runner.json"
  echo '{"run_id": "main-20261001t200000z", "phase": "drill"}' >"$current"
  rm "$work/box/run/secrets/piri-s3.env"
  printf '%s\n' '-----BEGIN KEY-----' 'aGFybmVzcy1rZXktYm9keQ' '-----END KEY-----' >"$D/harness"
  case "$leak" in
    piri) echo "S3 {id: AKIAFAKE, key: fake-secret}" >>"$work/box/nvme/work/run/drill.out" ;;
    harness) echo "loaded aGFybmVzcy1rZXktYm9keQ" >>"$work/box/nvme/work/run/drill.out" ;;
  esac
  touch "$D/s3-down"
  recover_ok "$leak credential in the tree"
  has "$work/out" "a credential is still in the collected files"
  [ ! -e "$work/box/outbox/main-20261001t200000z.raw.tar.zst" ] || fail "tarball written with the $leak credential"
  python3 - "$work/box/outbox/main-20261001t200000z.json" <<'PY' || fail "record lacks raw_missing"
import json, sys
assert "raw_missing" in json.dumps(json.load(open(sys.argv[1])))
PY
  count "$D/containers" 0
done
echo "ok: a piri or harness credential in the collected files refuses the tarball and flags raw_missing"

# One piri read failing while the harness parameter answers must not pass.
for param in piri-s3-access-key-id piri-s3-secret-access-key; do
  setup
  cp "$host/fixtures/stack-boot-failed/runner.json" "$work/box/nvme/work/run/runner.json"
  echo '{"run_id": "main-20261001t200000z", "phase": "drill"}' >"$current"
  rm "$work/box/run/secrets/piri-s3.env"
  printf '%s\n' '-----BEGIN KEY-----' 'aGFybmVzcy1rZXktYm9keQ' '-----END KEY-----' >"$D/harness"
  echo "S3 {id: AKIAFAKE, key: fake-secret}" >>"$work/box/nvme/work/run/drill.out"
  echo "$param" >"$D/ssm-fail"
  if "$host/recover.sh" >"$work/out" 2>&1; then fail "recover passed with $param unreadable"; fi
  has "$work/out" "attempt 1 of 3, current.json kept"
  [ -e "$current" ] && [ "$(grep -c . "$D/containers")" = 4 ] || fail "$param failure wiped"
  [ -z "$(ls -A "$work/box/outbox")" ] || fail "outbox written with $param unreadable"
  rm "$D/ssm-fail"
done
echo "ok: a failed read of piri's key ID or secret keeps current.json and writes no tarball"

# A stop/start leaves the run directory blank; the root-volume copy of runner.json serves.
setup
rm -rf "$work/box/nvme/work/run"
cp "$host/fixtures/stack-boot-failed/runner.json" "$work/box/state/runner.json"
echo '{"run_id": "main-20261001t200000z", "phase": "drill"}' >"$current"
echo 3 >"$work/box/state/recover-attempts"
touch "$D/s3-down"
recover_ok "runner.json on the root volume"
[ -s "$work/box/outbox/main-20261001t200000z.json" ] || fail "no record from the root-volume runner.json"
[ ! -e "$current" ] && [ ! -e "$work/box/state/runner.json" ] || fail "state kept after recovery"
echo "ok: after a stop/start recovery builds the record from the root-volume runner.json"

# A wipe that keeps failing: kept for a retry, then set aside on the last attempt.
setup
echo '{"run_id": "main-20261001t200000z", "phase": "uploaded"}' >"$current"
echo smelt_minio-data >"$D/stuck"
if "$host/recover.sh" >"$work/out" 2>&1; then fail "recover passed with a failed wipe"; fi
has "$work/out" "the wipe failed; attempt 1 of 3"
[ -e "$current" ] || fail "current.json moved aside on attempt 1"
status=0
FORGE_PERF_RECOVER_ATTEMPTS=2 "$host/recover.sh" >"$work/out" 2>&1 || status=$?
[ "$status" = 4 ] || fail "the last failed wipe exited $status, want 4"
grep -qx "RestartPreventExitStatus=4" "$repo/systemd/forge-perf-recover.service" || fail "the unit restarts on exit 4"
has "$work/out" "the wipe failed on the last attempt"
[ ! -e "$current" ] || fail "current.json kept after the last failed wipe"
ls "$current".failed-* >/dev/null 2>&1 || fail "current.json not set aside"
[ ! -e "$work/box/state/recover-attempts" ] || fail "attempt count kept"
echo "ok: a wipe that fails on the last attempt moves current.json aside and exits 4, which the unit does not restart"

# The failure stays for the boot: a later start (a poll that requires the
# unit) exits 4 without touching the stack, until the marker in /run goes.
[ -e "$work/box/run/recover-failed" ] || fail "no recover-failed marker after the last failed wipe"
rm -f "$D/stuck" "$D/log"
status=0
"$host/recover.sh" >"$work/out" 2>&1 || status=$?
[ "$status" = 4 ] || fail "recovery after a failed last wipe exited $status, want 4"
has "$work/out" "an earlier recovery could not wipe"
lacks "$work/out" "no interrupted run"
[ ! -e "$D/log" ] || fail "recovery touched docker while the marker was set"
rm "$work/box/run/recover-failed"
"$host/recover.sh" >"$work/out" 2>&1 || { cat "$work/out"; fail "recovery after the marker went failed"; }
has "$work/out" "no interrupted run"
echo "ok: after a failed last wipe every later recovery exits 4 until the marker is gone"

# Without current.json a stale attempt count goes away.
setup
echo 2 >"$work/box/state/recover-attempts"
"$host/recover.sh" >/dev/null 2>&1
[ ! -e "$work/box/state/recover-attempts" ] || fail "stale attempt count kept"
echo "ok: recovery without current.json clears a stale attempt count"

# A reboot after the drill started: the record blames the interrupt, not the runner.
setup
python3 - "$host/fixtures/valid/runner.json" "$work/box/nvme/work/run/runner.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["time"]["drill_started_at"]
r["time"].update(drill_finished_at=None, run_finished_at=None)
json.dump(r, open(sys.argv[2], "w"))
PY
echo '{"run_id": "main-20261001t120000z", "phase": "drill"}' >"$current"
touch "$D/s3-down"
recover_ok "a drill that started"
python3 - "$work/box/outbox/main-20261001t120000z.json" <<'PY' || fail "a started drill's record is not no_data/[drill_interrupted]"
import json, sys
o = json.load(open(sys.argv[1]))["outcome"]
assert (o["class"], o["reasons"]) == ("no_data", ["drill_interrupted"]), o
PY
echo "ok: recovery of a drill that started records only drill_interrupted"

# A collection step that fails (zstd on a full disk) and a failing docker stop still wipe.
setup
cp "$host/fixtures/stack-boot-failed/runner.json" "$work/box/nvme/work/run/runner.json"
echo '{"run_id": "main-20261001t200000z", "phase": "drill"}' >"$current"
mkdir -p "$work/fullbin"
printf '#!/usr/bin/env bash\necho "zstd: No space left on device" >&2\nexit 1\n' >"$work/fullbin/zstd"
chmod +x "$work/fullbin/zstd"
touch "$D/s3-down" "$D/stop-fails"
PATH="$work/fullbin:$PATH" "$host/recover.sh" >"$work/out" 2>&1 || { cat "$work/out"; fail "recover failed on a failed collection"; }
rm -f "$D/stop-fails"
has "$work/out" "collecting the raw tarball failed"
has "$work/out" "docker stop failed"
[ -z "$(find "$work/box/outbox" -name '*.raw.tar.zst*')" ] || fail "a partial tarball was left"
[ ! -e "$work/box/nvme/work/recover-raw" ] || fail "the stage was left"
python3 - "$work/box/outbox/main-20261001t200000z.json" <<'PY' || fail "record lacks raw_missing"
import json, sys
assert "raw_missing" in json.dumps(json.load(open(sys.argv[1])))
PY
count "$D/containers" 0
[ ! -e "$current" ] || fail "current.json kept after a failed collection"
echo "ok: a failed collection or docker stop costs the tarball, and recovery still records and wipes"

# A runner copy another run's recovery left behind is not reused, and the
# SSM parameter names follow FORGE_PERF_SSM_PATH.
setup
echo '{"run_id": "main-20261001t200000z", "reasons": []}' >"$work/box/state/recover-runner.json"
python3 - "$host/fixtures/stack-boot-failed/runner.json" "$work/box/nvme/work/run/runner.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r["run_id"] = "main-20261002t100000z"
json.dump(r, open(sys.argv[2], "w"))
PY
echo '{"run_id": "main-20261002t100000z", "phase": "drill"}' >"$current"
rm "$work/box/run/secrets/piri-s3.env"
touch "$D/s3-down"
: >"$D/aws.log"
FORGE_PERF_SSM_PATH=/other recover_ok "a stale recover-runner.json"
has "$D/aws.log" "--name /other/piri-s3-secret-access-key"
python3 - "$work/box/outbox/main-20261002t100000z.json" <<'PY' || fail "the record carries another run's run_id"
import json, sys
assert json.load(open(sys.argv[1]))["run_id"] == "main-20261002t100000z"
PY
setup
echo '{"run_id": "main-20261001t200000z", "reasons": []}' >"$work/box/state/recover-runner.json"
"$host/recover.sh" >/dev/null 2>&1
[ ! -e "$work/box/state/recover-runner.json" ] || fail "recovery without current.json kept recover-runner.json"
echo "ok: a stale recover-runner.json is dropped, and SSM names follow FORGE_PERF_SSM_PATH"
