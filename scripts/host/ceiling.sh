#!/usr/bin/env bash
# Measure this box's two ceilings and upload the evidence (docs/DESIGN.md §9,
# calibration/README.md). scripts/operator/calibrate-ceilings.sh runs it over
# SSM on a campaign box started with mode=calibration.
#
#   ceiling.sh --date YYYY-MM-DD [--quick] [--workers N]
#
# 1. host.json: the facts that identify the measurement.
# 2. S3 PUT: builds cmd/s3-ceiling with the box's Go and runs it with piri's
#    key against the box's own pdp bucket, 8 workers per vCPU. m9gd.2xlarge
#    runs 75 minutes and scores the last 30 once its burst allowance is spent;
#    the other types are rated sustained and run 30 minutes, the first 5
#    dropped. Half and twice the workers follow for 10 minutes each.
# 3. NVMe write: ceiling-nvme.sh, which wipes the drive.
# 4. Combined, for reference: 10 minutes of S3 PUT while fio writes a file on
#    the drive's filesystem.
# 5. summary.json, then everything to
#    s3://<results bucket>/raw/calibration/<date>/<instance type>/.
# --workers N replaces the main phase's 8 per vCPU, for a type whose run at
# twice the workers came out faster (the summary's under_driven flag).
# --quick runs a few minutes of each, skips the combined phase and marks the
# summary, to check the path end to end.
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

date="" quick="" workers=""
while [ $# -gt 0 ]; do
  case "$1" in
    --date) date="${2:-}"; shift ;;
    --quick) quick=1 ;;
    --workers) workers="${2:-}"; shift ;;
    *) die "usage: ceiling.sh --date YYYY-MM-DD [--quick] [--workers N]" ;;
  esac
  shift
done
[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "usage: ceiling.sh --date YYYY-MM-DD [--quick] [--workers N]"
[[ -z "$workers" || "$workers" =~ ^[1-9][0-9]{0,3}$ ]] || die "--workers takes 1 to 9999"

runner_init
export AWS_REGION="${FORGE_PERF_REGION:-us-east-2}"
conf="${FORGE_PERF_CAMPAIGN_CONF:-/etc/forge-perf/campaign.json}"
[ "${FORGE_PERF_MODE:-}" = campaign ] && [ "$(jq -r '.mode // ""' "$conf" 2>/dev/null)" = calibration ] ||
  die "ceiling.sh wipes the instance store; it runs only on a campaign box in mode calibration"

type="$(imds instance-type)"
out="${FORGE_PERF_CEILING_DIR:-/var/lib/forge-perf/ceiling}/$date/$type"
rm -rf "$out"
mkdir -p "$out"
bin="$(dirname "$out")/s3-ceiling"

step "build s3-ceiling"
# The SSM agent's environment may carry no HOME, so Go gets run.sh's caches.
go_cache="${FORGE_PERF_GO_CACHE-/var/cache/forge-perf/go}"
[ -z "$go_cache" ] || export GOCACHE="$go_cache/build" GOMODCACHE="$go_cache/mod"
(cd "$FORGE_PERF_CHECKOUT" && GOTOOLCHAIN=local GOFLAGS=-mod=readonly go build -o "$bin" ./cmd/s3-ceiling)

# awk reads to the end: exiting at the first line can end ip with SIGPIPE.
iface="$(host_read ip -o route show default | awk 'iface == "" { iface = $5 } END { if (iface != "") print iface }')"
ssm="${FORGE_PERF_SSM_PATH:-/forge-perf}"
if ! FORGE_PERF_PIRI_S3_KEY_ID="$(ssm_value "$ssm/piri-s3-access-key-id")" ||
  ! FORGE_PERF_PIRI_S3_SECRET="$(ssm_value "$ssm/piri-s3-secret-access-key")"; then
  die "cannot read piri's S3 key from SSM"
fi
export FORGE_PERF_PIRI_S3_KEY_ID FORGE_PERF_PIRI_S3_SECRET

step "host facts"
q() { ( "$@" ) 2>/dev/null || true; }
jq -n --arg type "$type" --arg id "$(q imds instance-id)" --arg az "$(q imds placement/availability-zone)" \
  --arg ami "$(q imds ami-id)" --arg kernel "$(uname -r)" --arg iface "$iface" \
  --arg ena "$(q host_read ethtool -i "$iface" | awk -F': ' '$1 == "driver" || $1 == "version" { print $2 }' | paste -sd' ' -)" \
  --arg fio "$(q fio --version)" --arg go "$(go env GOVERSION)" \
  --arg minio "$(go version -m "$bin" | awk '$2 == "github.com/minio/minio-go/v7" { print $3 }')" \
  --arg sha "$(git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)" --argjson vcpus "$(nproc)" \
  '{instance_type: $type, instance_id: $id, availability_zone: $az, ami_id: $ami, kernel: $kernel,
    vcpus: $vcpus, nic: $iface, ena_driver: $ena, fio: $fio, go: $go, minio_go: $minio, forge_perf_sha: $sha}' \
  >"$out/host.json"

w="${workers:-$((8 * $(nproc)))}"
put=("$bin" put -endpoint "$FORGE_PERF_PIRI_S3_ENDPOINT" -bucket "${FORGE_PERF_PIRI_BUCKET_PREFIX:?}pdp"
  -iface "$iface" -object-bytes 134217728)
[ "$FORGE_PERF_PIRI_S3_INSECURE" != true ] || put+=(-insecure)
if [ -n "$quick" ]; then
  schedule=(-phase "$w:3m" -phase "$((2 * w)):1m" -score-drop 30s)
elif [ "$type" = m9gd.2xlarge ]; then
  schedule=(-phase "$w:75m" -phase "$((w / 2)):10m" -phase "$((2 * w)):10m"
    -score-last 30m -burst-check 60m -burst-max 120m)
else
  schedule=(-phase "$w:30m" -phase "$((w / 2)):10m" -phase "$((2 * w)):10m" -score-drop 5m)
fi

step "S3 PUT, $w workers"
"${put[@]}" -prefix "ceiling/$date/" -out "$out" "${schedule[@]}"

[ "$(jq -r '.windows' "$out/s3-put.json")" -gt 0 ] || die "the S3 phase scored no 30 s window"

step "NVMe write"
nvme_args=(--out "$out" --scorer "$bin")
[ -z "$quick" ] || nvme_args+=(--quick)
"$here/ceiling-nvme.sh" "${nvme_args[@]}"

combined=null
if [ -z "$quick" ]; then
  step "combined"
  mkdir -p "$out/combined"
  "${put[@]}" -prefix "ceiling/$date/combined/" -out "$out/combined" -phase "$w:10m" -score-drop 30s &
  pid=$!
  # Each job's region is 25 GB rounded down to whole MiB, for O_DIRECT.
  (cd "$out/combined" && host_op fio --name=seqwrite --filename="$FORGE_PERF_NVME_MOUNT/scratch/combined.fio" \
    --direct=1 --ioengine=io_uring --rw=write --bs=1M --iodepth=32 --numjobs=4 --group_reporting \
    --size=24999100416 --offset_increment=24999100416 --time_based --runtime=600 \
    --write_bw_log=combined --log_avg_msec=1000 --output-format=json --output=combined-fio.json)
  wait "$pid"
  host_op rm -f "$FORGE_PERF_NVME_MOUNT/scratch/combined.fio"
  combined="$(jq -n --argjson s3 "$(cat "$out/combined/s3-put.json")" \
    --argjson fio "$("$bin" fio -skip 30s "$out"/combined/combined_bw.*.log)" \
    '{s3_put_median: $s3.median, nvme_median: $fio.median}')"
fi

step "summary"
jq -n --arg date "$date" --argjson quick "${quick:-0}" --argjson host "$(cat "$out/host.json")" \
  --argjson s3 "$(cat "$out/s3-put.json")" --argjson nvme "$(cat "$out/nvme.json")" --argjson combined "$combined" '
  {date: $date, instance_type: $host.instance_type, quick: ($quick == 1), forge_perf_sha: $host.forge_perf_sha,
   window_seconds: 30, statistic: "p5 and median of 30 s windows over the sustained segment", units: "bytes/s",
   s3_put: ($s3 | {p5, median, windows, workers, object_bytes, sustained_from_s, burst_ended_s, errors, flags,
                   minio_go, method: "cmd/s3-ceiling: minio-go PutObject, non-seekable body, TLS, piri key, pdp bucket"}),
   nvme_write: ($nvme | {p5, median, windows, device_bytes, limited_by_fs,
                         pass2_median: $nvme.pass2.median, fs_median: $nvme.fs.median,
                         method: "fio after blkdiscard, 1 MiB, QD32 x 4 jobs, O_DIRECT, whole device"}),
   combined: $combined}
  | .ceiling = ([.s3_put.p5, .nvme_write.p5] | min)
  | .limited_by = (if .s3_put.p5 <= .nvme_write.p5 then "s3_put" else "nvme_write" end)' >"$out/summary.json"
jq -c '{ceiling, limited_by, s3_p5: .s3_put.p5, nvme_p5: .nvme_write.p5}' "$out/summary.json"

dest="s3://${FORGE_PERF_RESULTS_BUCKET:?}/raw/calibration/$date/$type/"
step "upload to $dest"
aws s3 cp --recursive --only-show-errors "$out/" "$dest"
