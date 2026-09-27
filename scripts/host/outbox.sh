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
# raw tarball is still here. The box never reads the bucket back.
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
left=0

for raw in "$FORGE_PERF_OUTBOX"/*.raw.tar.zst; do
  [ -e "$raw" ] || continue
  id="$(basename "$raw" .raw.tar.zst)"
  if aws s3 cp "$raw" "s3://$bucket/raw/$box/$id/raw.tar.zst" --checksum-algorithm SHA256 --only-show-errors; then
    rm -f "$raw"
    echo "outbox: raw $id uploaded"
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
  if out="$(aws s3api put-object --bucket "$bucket" --key "published/$box/$id.json" --body "$record" \
    --content-type application/json --content-md5 "$md5" --if-none-match '*' 2>&1)"; then
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
