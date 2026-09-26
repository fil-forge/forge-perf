#!/usr/bin/env bash
# Behavior of ceiling.sh and ceiling-nvme.sh against stubs. go build leaves a
# stub s3-ceiling that writes its files and scores fio logs from $P1, $P2,
# $FS; fio writes four bandwidth logs; aws answers SSM and copies the upload
# into $D/s3. Every host command is appended to $D/calls, so each case checks
# what ran, with which arguments and in what order.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2016
set -euo pipefail

host="$(cd "$(dirname "$0")/.." && pwd -P)"
repo="$(cd "$host/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ceiling-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export D="$work/d"
mkdir -p "$work/bin"
unset INVOCATION_ID FORGE_PERF_HOST_OPS

stub() { # name body: a stub that logs its call, then runs body
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$D/calls"\n%s\n' "$1" "${2:-}" >"$work/bin/$1"
  chmod +x "$work/bin/$1"
}
printf '#!/usr/bin/env bash\necho 0\n' >"$work/bin/id"
printf '#!/usr/bin/env bash\necho "${NPROC:-8}"\n' >"$work/bin/nproc"
chmod +x "$work/bin/id" "$work/bin/nproc"
# Instance metadata: a token, then the path's last element.
stub curl 'case "$*" in
  *api/token*) echo token ;;
  *instance-type) echo "$TYPE" ;;
  *availability-zone) echo us-east-2a ;;
  *) echo "i-0123" ;;
esac'
stub lsblk 'case "$*" in *SIZE*) echo 474000000000 ;; *) echo "/dev/nvme1n1 Amazon EC2 NVMe Instance Storage" ;; esac'
stub blkid 'exit 2'
stub systemctl '[ "$1" != is-active ] || exit 3'
for c in umount mount blkdiscard mkfs.ext4 sync sysctl; do stub "$c"; done
stub mountpoint 'exit 0'
stub ip 'echo "default via 10.0.0.1 dev ens5 proto dhcp"'
stub ethtool 'printf "driver: ena\nversion: 2.13\n"'
stub fio 'for a; do case "$a" in --write_bw_log=*) n="${a#*=}" ;; --output=*) o="${a#*=}" ;; esac; done
[ "$*" != --version ] || { echo fio-3.36; exit 0; }
for j in 1 2 3 4; do echo "1000, 1024, 1, 1048576, 0" >"${n}_bw.$j.log"; done
echo "{}" >"$o"'
stub go 'case "$1" in
  build) cp "$WORK/s3-ceiling" "$3" ;;
  env) echo go1.26.8 ;;
  version) printf "%s: go1.26.8\n\tdep\tgithub.com/minio/minio-go/v7\tv7.3.0\th1:x\n" "$3" ;;
esac'
stub aws 'case "$1 $2" in
  "ssm get-parameter") echo "secret-of-${5##*/}" ;;
  "s3 cp") mkdir -p "$D/s3" && cp -R "$5". "$D/s3/" && echo "$6" >"$D/dest" ;;
esac'
# The s3-ceiling that go build "produces".
cat >"$work/s3-ceiling" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = fio ]; then
  case "$4" in
    nvme-pass1*) v="$P1" ;; nvme-pass2*) v="$P2" ;; nvme-fs*) v="$FS" ;; *) v=5 ;;
  esac
  echo "{\"p5\": $v, \"median\": $((v + 1)), \"windows\": 10}"
  exit 0
fi
echo "s3-ceiling $* key=$FORGE_PERF_PIRI_S3_KEY_ID" >>"$D/calls"
while [ $# -gt 0 ]; do [ "$1" != -out ] || out="$2"; shift; done
echo "t,bytes,objects_done,errors,workers" >"$out/s3-put.csv"
echo "t,bw_out_allowance_exceeded,pps_allowance_exceeded,conntrack_allowance_exceeded" >"$out/ena.csv"
echo "{\"p5\": $S3, \"median\": $((S3 + 1)), \"windows\": 60, \"workers\": 64, \"object_bytes\": 134217728,
  \"sustained_from_s\": 2700, \"burst_ended_s\": 1200, \"errors\": 0, \"flags\": [], \"minio_go\": \"v7.3.0\"}" >"$out/s3-put.json"
STUB
chmod +x "$work/s3-ceiling"
export PATH="$work/bin:$PATH" WORK="$work"

git() { /usr/bin/git -C "$work/checkout" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$work/checkout/scripts" "$work/box/state"
cp -R "$repo/config" "$work/checkout/"
cp -R "$host" "$work/checkout/scripts/"
git init -q && git add -A && git commit -qm one
printf '%s\n' FORGE_PERF_BOX_ID=campaign FORGE_PERF_MODE=campaign "FORGE_PERF_CHECKOUT=$work/checkout" \
  FORGE_PERF_RESULTS_BUCKET=test-results FORGE_PERF_PIRI_BUCKET_PREFIX=pp-piri-0- >"$work/box/box.conf"
export FORGE_PERF_BOX_CONF="$work/box/box.conf" FORGE_PERF_CAMPAIGN_CONF="$work/box/campaign.json" \
  FORGE_PERF_STATE_DIR="$work/box/state" FORGE_PERF_RUNTIME="$work/box/run" FORGE_PERF_CEILING_DIR="$work/box/ceiling" \
  FORGE_PERF_NVME_MOUNT="$work/box/nvme" FORGE_PERF_VOLUMES_DIR="$work/box/volumes" FORGE_PERF_IMDS_URL=http://imds

fail() {
  echo "FAIL: $*" >&2
  sed 's/^/  | /' "$work/out" >&2 || true
  exit 1
}
ceiling() {
  local want="$1" got=0
  shift
  rm -rf "$D" && mkdir -p "$D"
  bash "$work/checkout/scripts/host/ceiling.sh" "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "ceiling.sh $* exited $got, wanted $want"
}
line() { grep -n "^$1" "$D/calls" | head -1 | cut -d: -f1; }
summary() { jq -r "$1" "$D/s3/summary.json"; }

echo '{"mode": "calibration"}' >"$work/box/campaign.json"
export TYPE=m9gd.2xlarge S3=500000000 P1=2000000000 P2=1500000000 FS=1900000000
ceiling 0 --date 2026-10-06
grep -q -- "put -endpoint s3.us-east-2.amazonaws.com -bucket pp-piri-0-pdp -iface ens5 -object-bytes 134217728 -prefix ceiling/2026-10-06/ -out $work/box/ceiling/2026-10-06/m9gd.2xlarge -phase 64:75m -phase 32:10m -phase 128:10m -score-last 30m -burst-check 60m -burst-max 120m key=secret-of-piri-s3-access-key-id" "$D/calls" ||
  fail "the tier 1 schedule, bucket and key"
[ "$(cat "$D/dest")" = s3://test-results/raw/calibration/2026-10-06/m9gd.2xlarge/ ] || fail "upload destination"
for f in host.json s3-put.csv ena.csv s3-put.json nvme-pass1_bw.1.log nvme-pass2_bw.4.log nvme-fs_bw.1.log \
  nvme-pass1.json nvme.json summary.json combined/s3-put.json combined/combined_bw.1.log; do
  [ -f "$D/s3/$f" ] || fail "$f was not uploaded"
done
s="$(line systemctl.stop.docker)" b="$(line blkdiscard)" p1="$(line 'fio.*nvme-pass1')" p2="$(line 'fio.*nvme-pass2')"
m="$(line mkfs.ext4)" fs="$(line 'fio.*nvme-fs')" c="$(line 'fio.*combined')"
[ "$s" -lt "$b" ] && [ "$b" -lt "$p1" ] && [ "$p1" -lt "$p2" ] && [ "$p2" -lt "$m" ] && [ "$m" -lt "$fs" ] && [ "$fs" -lt "$c" ] ||
  fail "order: docker stop $s, discard $b, pass1 $p1, pass2 $p2, mkfs $m, fs $fs, combined $c"
grep -q "blkdiscard -f /dev/nvme1n1" "$D/calls" || fail "the discard targets the instance store"
grep "fio.*nvme-pass1" "$D/calls" | grep -q -- "--filename=/dev/nvme1n1 --direct=1 --ioengine=io_uring --rw=write --bs=1M --iodepth=32 --numjobs=4 .*--size=25% --offset_increment=25%$" ||
  fail "pass 1 is the whole device, four regions"
grep "fio.*nvme-fs" "$D/calls" | grep -q -- "--size=25000000000 --offset_increment=25000000000" || fail "a 100 GB file"
[ "$(summary '[.ceiling, .limited_by, .s3_put.p5, .nvme_write.p5, .nvme_write.limited_by_fs, .quick] | join(" ")')" = \
  "500000000 s3_put 500000000 2000000000 false false" ] || fail "the ceiling is the lower, S3"
[ "$(summary '[.combined.s3_put_median, .combined.nvme_median, .s3_put.burst_ended_s] | join(" ")')" = "500000001 6 1200" ] ||
  fail "combined medians"
[ "$(jq -r '[.minio_go, .go, .fio, .ena_driver, .vcpus] | join(" ")' "$D/s3/host.json")" = "v7.3.0 go1.26.8 fio-3.36 ena 2.13 8" ] ||
  fail "host facts"
echo "ok: tier 1 measures S3 through piri's bucket, then the drive, then both, and uploads the evidence"

export S3=900000000 FS=1700000000
ceiling 0 --date 2026-10-06
[ "$(summary '[.ceiling, .limited_by, .nvme_write.limited_by_fs, .nvme_write.p5] | join(" ")')" = \
  "900000000 s3_put true 1700000000" ] || fail "a filesystem 15% below the raw device sets the drive's figure"
export S3=2500000000
ceiling 0 --date 2026-10-06
[ "$(summary '.limited_by')" = nvme_write ] || fail "a drive slower than S3 limits the ceiling"
echo "ok: the filesystem figure replaces the raw one below 90%, and the lower measurement limits"

export TYPE=m9gd.8xlarge NPROC=32 S3=500000000
ceiling 0 --date 2026-10-07 --quick
grep -q -- "-phase 256:3m -phase 512:1m -score-drop 30s" "$D/calls" || fail "quick S3 schedule"
grep "fio.*nvme-pass1" "$D/calls" | grep -q -- "--runtime=60" || fail "quick pass 1 is capped"
! grep -q "nvme-pass2\|combined" "$D/calls" || fail "quick runs no pass 2 and no combined phase"
grep "fio.*nvme-fs" "$D/calls" | grep -q -- "--size=2500000000 " || fail "a 10 GB file"
[ "$(summary '[.quick, .combined, .nvme_write.pass2_median] | join(" ")')" = "true  " ] || fail "quick summary"
[ "$(cat "$D/dest")" = s3://test-results/raw/calibration/2026-10-07/m9gd.8xlarge/ ] || fail "quick upload"
unset NPROC
ceiling 0 --date 2026-10-07
grep -q -- "-phase 64:30m -phase 32:10m -phase 128:10m -score-drop 5m" "$D/calls" || fail "a sustained type's schedule"
ceiling 0 --date 2026-10-07 --workers 100
grep -q -- "-phase 100:30m -phase 50:10m -phase 200:10m -score-drop 5m" "$D/calls" || fail "--workers sets the main phase"
echo "ok: --quick and the sustained types' schedule"

echo '{"mode": "campaign"}' >"$work/box/campaign.json"
ceiling 1 --date 2026-10-07
grep -q "only on a campaign box in mode calibration" "$work/out" || fail "refusal message"
[ ! -e "$D/calls" ] || ! grep -q "blkdiscard\|s3-ceiling" "$D/calls" || fail "a refused run touched the drive or S3"
echo '{"mode": "calibration"}' >"$work/box/campaign.json"
ceiling 1 --date 10/07/2026
ceiling 1 --date 2026-10-07 --workers 0
touch "$work/box/state/current.json"
rm -rf "$D" && mkdir -p "$D"
bash "$work/checkout/scripts/host/ceiling-nvme.sh" --out "$work/nv" --scorer "$work/s3-ceiling" >"$work/out" 2>&1 &&
  fail "ceiling-nvme.sh ran during a run"
! grep -q blkdiscard "$D/calls" 2>/dev/null || fail "discarded during a run"
echo "ok: refused outside a calibration box, with a bad date, and during a run"
