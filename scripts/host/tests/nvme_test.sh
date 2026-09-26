#!/usr/bin/env bash
# Behavior of nvme.sh boot with lsblk, blkid, mkfs.ext4, mount and the rest
# stubbed on PATH. Every stubbed call is appended to $LOG, so each case checks
# which commands ran and in what order.
# SC2015: `check && echo ok || fail` is the intended shape; fail runs when
# either the check or the echo fails, and echo does not fail.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd -P)/nvme.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/nvme-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export LOG="$work/calls" WORK="$work"

# lsblk prints $WORK/lsblk; blkid prints $WORK/label if it exists;
# `systemctl is-active` succeeds when $WORK/docker-active exists.
cat >"$work/bin/lsblk" <<'STUB'
#!/usr/bin/env bash
cat "$WORK/lsblk"
STUB
cat >"$work/bin/blkid" <<'STUB'
#!/usr/bin/env bash
echo "blkid $*" >>"$LOG"
[ -f "$WORK/label" ] && cat "$WORK/label" || exit 2
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$LOG"
[ "$1" != is-active ] || [ -f "$WORK/docker-active" ]
STUB
cat >"$work/bin/mountpoint" <<'STUB'
#!/usr/bin/env bash
echo "mountpoint $*" >>"$LOG"
exit 1
STUB
# mount fails once, for the first `mount -o`, when $WORK/mount-fails exists.
cat >"$work/bin/mount" <<'STUB'
#!/usr/bin/env bash
echo "mount $*" >>"$LOG"
if [ "$1" = -o ] && [ -f "$WORK/mount-fails" ]; then rm "$WORK/mount-fails"; exit 32; fi
STUB
for c in mkfs.ext4 umount install sync sysctl; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$LOG"\n' "$c" >"$work/bin/$c"
done
chmod +x "$work/bin/"*

one_store='/dev/nvme0n1 Amazon Elastic Block Store
/dev/nvme1n1 Amazon EC2 NVMe Instance Storage'

failures=0
out="$work/out"

# run <want-status> <description> [VAR=value ...]: fresh state, then nvme.sh boot.
run() {
  local want="$1" what="$2" got=0
  shift 2
  : >"$LOG"
  env -u INVOCATION_ID PATH="$work/bin:$PATH" FORGE_PERF_STATE_DIR="$work/state" \
    FORGE_PERF_NVME_MOUNT=/mnt/forge-perf/nvme FORGE_PERF_VOLUMES_DIR=/var/lib/docker/volumes \
    "$@" bash "$script" boot >"$out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    fail "$what: exit $got, want $want"
    return 1
  fi
}

fail() {
  echo "FAIL: $*"
  sed 's/^/    /' "$out" "$LOG"
  failures=$((failures + 1))
}

called() { grep -qxF "$1" "$LOG"; }

reset() {
  rm -rf "$work/state" "$work/label" "$work/docker-active" "$work/mount-fails"
  mkdir -p "$work/state"
  printf '%s\n' "$one_store" >"$work/lsblk"
}

reset
if run 0 "fresh device"; then
  called "mkfs.ext4 -F -q -m 0 -L forge-perf-nvme -E lazy_itable_init=0,lazy_journal_init=0 /dev/nvme1n1" &&
    called "mount -o noatime /dev/nvme1n1 /mnt/forge-perf/nvme" &&
    called "mount --bind /mnt/forge-perf/nvme/docker-volumes /var/lib/docker/volumes" &&
    called "sysctl -q vm.drop_caches=3" &&
    grep -q '^formatted /dev/nvme1n1 in [0-9]* s$' "$out" &&
    [ "$(grep -n '^mount -o' "$LOG" | cut -d: -f1)" -lt "$(grep -n '^mount --bind' "$LOG" | cut -d: -f1)" ] &&
    echo "ok: fresh device is formatted, mounted, bound, and the format time logged" ||
    fail "fresh device: calls differ"
fi

reset
echo forge-perf-nvme >"$work/label"
touch "$work/state/current.json"
if run 0 "reboot during a run"; then
  ! grep -q '^mkfs' "$LOG" && called "mount --bind /mnt/forge-perf/nvme/docker-volumes /var/lib/docker/volumes" &&
    echo "ok: labeled device with current.json is mounted without formatting" ||
    fail "reboot during a run: formatted or did not bind"
fi

reset
echo forge-perf-nvme >"$work/label"
touch "$work/state/current.json" "$work/mount-fails"
if run 0 "reboot during a run, mount fails"; then
  [ "$(grep -c '^mount -o noatime /dev/nvme1n1 ' "$LOG")" -eq 2 ] && grep -q '^mkfs.ext4' "$LOG" &&
    [ "$(grep -n '^mkfs' "$LOG" | cut -d: -f1)" -lt "$(grep -n '^mount --bind' "$LOG" | cut -d: -f1)" ] &&
    grep -qxF "mount failed; formatting" "$out" &&
    echo "ok: a labeled device that fails to mount mid-run is formatted, so Docker can start" ||
    fail "reboot during a run, mount fails"
fi

reset
echo forge-perf-nvme >"$work/label"
if run 0 "reboot between runs"; then
  grep -q '^mkfs.ext4' "$LOG" && echo "ok: labeled device without current.json is formatted" ||
    fail "reboot between runs: not formatted"
fi

reset
echo other-label >"$work/label"
touch "$work/state/current.json"
if run 0 "foreign label"; then
  grep -q '^mkfs.ext4' "$LOG" && echo "ok: a device without our label is formatted even mid-run" ||
    fail "foreign label: not formatted"
fi

reset
printf '%s\n%s\n' "$one_store" '/dev/nvme2n1 Amazon EC2 NVMe Instance Storage' >"$work/lsblk"
if run 1 "two instance-store devices"; then
  ! grep -q '^mkfs' "$LOG" && grep -q 'found 2' "$out" && echo "ok: two devices refused" ||
    fail "two devices: wrong refusal"
fi

reset
touch "$work/docker-active"
if run 1 "docker running"; then
  ! grep -q '^mkfs' "$LOG" && echo "ok: refuses while Docker runs" || fail "docker running: formatted"
fi

reset
if run 0 "skip mode" FORGE_PERF_HOST_OPS=skip FORGE_PERF_IMDS_URL=http://127.0.0.1:9; then
  [ ! -s "$LOG" ] && grep -q '^host-op skipped: mkfs.ext4 .* /dev/forge-perf-local-nvme$' "$out" &&
    grep -q '^host-op skipped: sysctl -q vm.drop_caches=3$' "$out" &&
    echo "ok: skip mode calls no host command and logs each one" ||
    fail "skip mode: a host command ran or was not logged"
fi

reset
if run 1 "skip mode under systemd" FORGE_PERF_HOST_OPS=skip INVOCATION_ID=0123abcd; then
  ! grep -q '^mkfs' "$LOG" && ! grep -q skipped "$out" && grep -q 'refused under systemd' "$out" &&
    echo "ok: skip mode from the unit's environment is refused before any step" ||
    fail "skip mode under systemd"
fi

if [ "$failures" -ne 0 ]; then
  echo "nvme_test: $failures failure(s)"
  exit 1
fi
echo "nvme_test: all passed"
