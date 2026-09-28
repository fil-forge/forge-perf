#!/usr/bin/env bash
# Fetch a traced run's traces from its raw tarball and summarize them
# (docs/operations.md, "Reading a run's traces").
#
#   scripts/operator/traces.sh <run_id> [--out DIR] [--jaeger]
#
# Copies s3://<results bucket>/raw/<box>/<run_id>/raw.tar.zst, where <box> is
# the run ID's first part, extracts the run's traces/ directory to DIR/traces/
# (default local/traces/<run_id>/, which git ignores) and runs
# trace-summary.py on DIR/traces/traces.jsonl. raw/ is readable with operator
# credentials for the dev account; the results role cannot read it.
#
# --jaeger then starts Jaeger v2 all-in-one from scripts/operator/images.lock
# as container forge-perf-jaeger, bound to 127.0.0.1 (UI on 16686, OTLP HTTP
# on 4318), POSTs each line of traces.jsonl to /v1/traces and prints the UI's
# URL. The container keeps the spans in memory until it is removed.
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib.sh
. "$here/lib.sh"

usage="usage: traces.sh <run_id> [--out DIR] [--jaeger]"
run_id="${1:-}"
shift || true
out="" jaeger=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="${2:-}"; [ -n "$out" ] || die "$usage"; shift ;;
    --jaeger) jaeger=1 ;;
    *) die "$usage" ;;
  esac
  shift
done
[[ "$run_id" =~ ^([a-z0-9]{2,12})-[0-9]{8}t[0-9]{6}z$ ]] || die "'$run_id' is not a run ID; $usage"
box="${BASH_REMATCH[1]}"

require aws
require zstd
require python3
if [ -n "$jaeger" ]; then
  require docker
  require curl
fi
repo="$(cd "$here/../.." && pwd -P)"
results="${FORGE_PERF_RESULTS_BUCKET:-forge-perf-results-654654381893}"
out="${out:-$repo/local/traces/$run_id}"
key="raw/$box/$run_id/raw.tar.zst"

work="$(mktemp -d "${TMPDIR:-/tmp}/forge-perf-traces.XXXXXX")"
trap 'rm -rf "$work"' EXIT
aws s3 cp --only-show-errors "s3://$results/$key" "$work/raw.tar.zst" ||
  die "cannot copy s3://$results/$key: no tarball (a raw_missing run, or older than 180 days) or no access; raw/ needs operator credentials for the dev account"

# collect.sh stages the run directory as run/, so the collector's files are
# ./run/traces/ in the tarball.
mkdir -p "$work/x"
status=0
zstd -dcq "$work/raw.tar.zst" | tar -xf - -C "$work/x" ./run/traces 2>"$work/tar.err" || status=$?
[ -d "$work/x/run/traces" ] ||
  die "no traces/ in the raw tarball of $run_id, so the run was not traced or the tarball is unreadable: $(head -3 "$work/tar.err")"
[ "$status" -eq 0 ] || die "cannot extract traces/ from the raw tarball: $(head -3 "$work/tar.err")"
mkdir -p "$out"
rm -rf "$out/traces"
mv "$work/x/run/traces" "$out/traces"
file="$out/traces/traces.jsonl"
[ -f "$file" ] || die "traces/ holds no traces.jsonl; $out/traces/collector.log may say why"
echo "traces of $run_id in $out/traces" >&2

python3 "$here/trace-summary.py" "$file"

[ -n "$jaeger" ] || exit 0

image="$(awk '$1 == "JAEGER_IMAGE" { sub(/:[^:\/]*$/, "", $2); print $2 "@" $3; exit }' "$here/images.lock")"
[[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || die "no JAEGER_IMAGE line in scripts/operator/images.lock"
docker rm -f forge-perf-jaeger >/dev/null 2>&1 || true
# The image declares VOLUME /tmp. A tmpfs there keeps `docker rm -f` from
# leaving an anonymous volume behind for every --jaeger.
docker run -d --name forge-perf-jaeger --tmpfs /tmp -p 127.0.0.1:16686:16686 -p 127.0.0.1:4318:4318 "$image" >/dev/null ||
  die "cannot start $image"

wait_s="${TRACES_JAEGER_WAIT_SECONDS:-60}"
deadline=$((SECONDS + wait_s))
until curl -fsS -o /dev/null http://127.0.0.1:16686/ 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] || die "Jaeger did not answer on 127.0.0.1:16686 within ${wait_s}s; docker logs forge-perf-jaeger, then docker rm -f forge-perf-jaeger"
  sleep 1
done

lines=0 refused=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  lines=$((lines + 1))
  printf '%s' "$line" | curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
    --data-binary @- http://127.0.0.1:4318/v1/traces 2>/dev/null || refused=$((refused + 1))
done <"$file"
echo "Jaeger took $((lines - refused)) of $lines lines" >&2
[ "$refused" -eq 0 ] || echo "Jaeger refused $refused; a truncated last line is expected after a reboot" >&2
[ "$lines" -gt "$refused" ] || die "Jaeger took none of the lines; docker rm -f forge-perf-jaeger stops it"
echo "Jaeger UI: http://127.0.0.1:16686/"
echo "stop it with: docker rm -f forge-perf-jaeger" >&2
