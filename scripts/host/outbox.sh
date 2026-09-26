#!/usr/bin/env bash
# Upload what the outbox holds, raw tarballs first, then records.
#
#   outbox.sh flush
#
# $FORGE_PERF_OUTBOX/<run_id>.raw.tar.zst goes to
# s3://$FORGE_PERF_RESULTS_BUCKET/raw/<box>/<run_id>/raw.tar.zst with a
# SHA-256 checksum; <run_id>.json goes to published/<box>/<run_id>.json with
# --content-md5 and --if-none-match '*', so a record is never overwritten. A
# zero exit, or a 412 on a record, removes the file. A record waits while its
# raw tarball is still here. The box never reads the bucket back. Each upload
# gets 15 minutes.
#
# The outbox holds at most FORGE_PERF_OUTBOX_CAP_BYTES (default 20 GB): past
# that the oldest raw tarballs go first, and records are never dropped. A raw
# tarball whose upload still fails 24 hours after it was written is dropped
# too. Either way its record gains the flag raw_missing before it goes up.
#
# Exit status 1 when anything is left; the next poll tries again.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

[ "${1:-}" = flush ] || die "usage: outbox.sh flush"
runner_init
bucket="${FORGE_PERF_RESULTS_BUCKET:-forge-perf-results-654654381893}"
box="$FORGE_PERF_BOX_ID"
cap="${FORGE_PERF_OUTBOX_CAP_BYTES:-20000000000}"
left=0

# drop_raw ID WHY: delete the run's raw tarball and flag its record, keeping
# the schema's order of flags. A record that cannot be flagged keeps its
# tarball, and the flush stops.
drop_raw() {
  local record="$FORGE_PERF_OUTBOX/$1.json"
  if [ -e "$record" ]; then
    jq --argjson order "$(jq -c .properties.outcome.properties.flags.items.enum \
      "$FORGE_PERF_CHECKOUT/schema/run-record.v1.json")" '.outcome.flags as $have |
      .outcome.flags = [$order[] | select(. as $f | $have + ["raw_missing"] | any(. == $f))]' \
      "$record" >"$record.tmp" || die "cannot flag record $1 raw_missing"
    mv "$record.tmp" "$record"
  fi
  rm -f "$FORGE_PERF_OUTBOX/$1.raw.tar.zst"
  echo "outbox: dropped raw $1 ($2)" >&2
}

# shellcheck disable=SC2045 # oldest first; run IDs hold no spaces or newlines
for raw in $(ls -tr "$FORGE_PERF_OUTBOX"/*.raw.tar.zst 2>/dev/null); do
  total="$(for f in "$FORGE_PERF_OUTBOX"/*; do wc -c <"$f"; done | awk '{ s += $1 } END { print s + 0 }')"
  [ "$total" -gt "$cap" ] || break
  drop_raw "$(basename "$raw" .raw.tar.zst)" "the outbox holds $total bytes"
done

for raw in "$FORGE_PERF_OUTBOX"/*.raw.tar.zst; do
  [ -e "$raw" ] || continue
  id="$(basename "$raw" .raw.tar.zst)"
  if timeout --kill-after=60 900 aws s3 cp "$raw" "s3://$bucket/raw/$box/$id/raw.tar.zst" \
    --checksum-algorithm SHA256 --only-show-errors; then
    rm -f "$raw"
    echo "outbox: raw $id uploaded"
  elif [ -n "$(find "$raw" -mmin +1440)" ]; then
    drop_raw "$id" "uploads failed for 24 hours"
  else
    left=1
  fi
done

for record in "$FORGE_PERF_OUTBOX"/*.json; do
  [ -e "$record" ] || continue
  id="$(basename "$record" .json)"
  if [ -e "$FORGE_PERF_OUTBOX/$id.raw.tar.zst" ]; then
    left=1
    continue
  fi
  md5="$(openssl dgst -md5 -binary "$record" | base64)"
  if out="$(timeout --kill-after=60 900 aws s3api put-object --bucket "$bucket" --key "published/$box/$id.json" \
    --body "$record" --content-type application/json --content-md5 "$md5" --if-none-match '*' 2>&1)"; then
    rm -f "$record"
    echo "outbox: record $id uploaded"
  elif grep -q PreconditionFailed <<<"$out"; then
    rm -f "$record"
    echo "outbox: record $id was already uploaded"
  else
    echo "$out" >&2
    left=1
  fi
done
exit "$left"
