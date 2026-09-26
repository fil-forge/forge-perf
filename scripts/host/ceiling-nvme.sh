#!/usr/bin/env bash
# Measure the instance-store NVMe's sequential write ceiling (docs/DESIGN.md
# §9, calibration/README.md).
#
#   ceiling-nvme.sh --out DIR --scorer BIN [--quick]
#
# Destroys everything on the drive, so it runs only on a calibration box
# (ceiling.sh checks) and never while a run is in progress. It stops Docker,
# unmounts the drive, discards it and runs:
#   pass 1   the whole device in four sequential regions, O_DIRECT, 1 MiB
#            blocks, queue depth 32 per job: the ceiling
#   pass 2   the same again without a discard: a full drive, for reference
#   fs       nvme.sh boot formats and mounts the drive as every boot does, and
#            the same job writes a 100 GB file through ext4; when this lands
#            more than 10% below pass 1 it sets the ceiling instead, since
#            ingot's spool writes through the filesystem
# --quick caps pass 1 at 60 s, skips pass 2 and writes a 10 GB file.
#
# Writes fio's bandwidth logs (1 s), its JSON reports and nvme.json to DIR,
# each pass scored by `BIN fio` as p5 and median of 30 s windows after the
# first 30 s. Docker starts again at the end.
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib.sh
. "$here/lib.sh"

out="" scorer="" quick=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="${2:?}"; shift ;;
    --scorer) scorer="${2:?}"; shift ;;
    --quick) quick=1 ;;
    *) die "usage: ceiling-nvme.sh --out DIR --scorer BIN [--quick]" ;;
  esac
  shift
done
[ -n "$out" ] && [ -x "$scorer" ] || die "usage: ceiling-nvme.sh --out DIR --scorer BIN [--quick]"
[ ! -e "$FORGE_PERF_STATE_DIR/current.json" ] || die "a run is in progress"
mkdir -p "$out"
cd "$out"

dev="$(instance_store_dev)"
bytes="$(host_read lsblk -dnbo SIZE "$dev" | tr -d ' ')"
step "instance store $dev, $bytes bytes"

host_op systemctl stop docker.socket docker.service
for m in "$FORGE_PERF_VOLUMES_DIR" "$FORGE_PERF_NVME_MOUNT"; do
  if host_check mountpoint -q "$m"; then
    host_op umount "$m"
  fi
done

# job NAME TARGET FIO-ARGS...: one fio job of four sequential writers.
job() {
  local name="$1" target="$2"
  shift 2
  host_op fio --name=seqwrite --filename="$target" --direct=1 --ioengine=io_uring \
    --rw=write --bs=1M --iodepth=32 --numjobs=4 --group_reporting \
    --write_bw_log="$name" --log_avg_msec=1000 \
    --output-format=json --output="$name.json" "$@"
}
scored() {
  local logs=("$1"_bw.*.log)
  [ -e "${logs[0]}" ] || die "fio wrote no bandwidth log for $1"
  "$scorer" fio -skip 30s "${logs[@]}"
}

step "discard"
host_op blkdiscard -f "$dev"
step "pass 1"
if [ -n "$quick" ]; then
  job nvme-pass1 "$dev" --size=25% --offset_increment=25% --runtime=60
else
  job nvme-pass1 "$dev" --size=25% --offset_increment=25%
fi
pass1="$(scored nvme-pass1)"
pass2=null
if [ -z "$quick" ]; then
  step "pass 2, full drive"
  job nvme-pass2 "$dev" --size=25% --offset_increment=25%
  pass2="$(scored nvme-pass2)"
fi

step "filesystem"
"$here/nvme.sh" boot
gb=100
[ -z "$quick" ] || gb=10
file="$FORGE_PERF_NVME_MOUNT/scratch/ceiling.fio"
job nvme-fs "$file" --size=$((gb * 250000000)) --offset_increment=$((gb * 250000000))
fs="$(scored nvme-fs)"
host_op rm -f "$file"
host_op systemctl start docker.service

jq -n --arg dev "$dev" --argjson bytes "${bytes:-null}" --argjson p1 "$pass1" --argjson p2 "$pass2" \
  --argjson fs "$fs" --argjson gb "$gb" --argjson quick "${quick:-0}" '
  ($fs.p5 < 0.9 * $p1.p5) as $by_fs
  | {device: $dev, device_bytes: $bytes, quick: ($quick == 1), fs_file_bytes: ($gb * 1e9),
     pass1: $p1, pass2: $p2, fs: $fs, limited_by_fs: $by_fs,
     p5: (if $by_fs then $fs.p5 else $p1.p5 end),
     median: (if $by_fs then $fs.median else $p1.median end),
     windows: (if $by_fs then $fs.windows else $p1.windows end)}' >nvme.json
step "NVMe write p5 $(jq -r .p5 nvme.json) bytes/s"
