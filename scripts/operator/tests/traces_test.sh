#!/usr/bin/env bash
# Behavior of traces.sh with aws, docker and curl stubbed on PATH: which key
# it copies, where the traces land, what it refuses, and how --jaeger starts
# Jaeger and loads the file. The tarball is built as collect.sh builds one,
# with scripts/operator/fixtures/traces/traces.jsonl as run/traces/, and the
# scripts run from a copy beside an images.lock of the test's own.
# SC2015: `check && echo ok || fail` is the intended shape; fail runs when
# either the check or the echo fails, and echo does not fail.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/traces-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/operator" "$work/stage/run/traces" "$work/stage/logs" "$work/bare/run" "$work/bare/logs"
export LOG="$work/calls" WORK="$work"

cp "$dir/traces.sh" "$dir/lib.sh" "$dir/trace-summary.py" "$work/operator/"
digest="sha256:$(printf 'd%.0s' {1..64})"
echo "JAEGER_IMAGE  jaegertracing/jaeger:9.9.9  $digest" >"$work/operator/images.lock"

cp "$dir/fixtures/traces/traces.jsonl" "$work/stage/run/traces/"
echo "collector log" >"$work/stage/run/traces/collector.log"
echo "service log" >"$work/stage/logs/ingot.log"
tar -C "$work/stage" -cf - . | zstd -q -o "$work/traced.tar.zst"
echo "service log" >"$work/bare/logs/ingot.log"
tar -C "$work/bare" -cf - . | zstd -q -o "$work/untraced.tar.zst"

# Arguments one per line, a blank line between calls. aws s3 cp copies
# $WORK/raw.tar.zst to its destination, or fails when that file is absent.
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" "" >>"$LOG"
[ -e "$WORK/raw.tar.zst" ] || { echo "fatal error: An error occurred (403) when calling the HeadObject operation: Forbidden" >&2; exit 1; }
cp "$WORK/raw.tar.zst" "${@: -1}"
STUB
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' docker "$@" "" >>"$LOG"
STUB
# A GET fails while $WORK/ui-down exists. A POST takes a body that parses as
# JSON and refuses any other, as the OTLP receiver does.
cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' curl "$@" "" >>"$LOG"
case " $* " in
  *" -X POST "*) python3 -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null || exit 22 ;;
  *) [ ! -e "$WORK/ui-down" ] || exit 7 ;;
esac
STUB
# tar logs its arguments and runs the real tar.
real_tar="$(command -v tar)"
cat >"$work/bin/tar" <<STUB
#!/usr/bin/env bash
printf '%s\n' tar "\$@" "" >>"\$LOG"
exec "$real_tar" "\$@"
STUB
chmod +x "$work/bin/aws" "$work/bin/docker" "$work/bin/curl" "$work/bin/tar"

failures=0
fail() {
  echo "FAIL: $*"
  sed 's/^/    /' "$work/out"
  failures=$((failures + 1))
}
run() {
  local want="$1" what="$2" got=0
  shift 2
  : >"$LOG"
  env PATH="$work/bin:$PATH" "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" -eq "$want" ] || { fail "$what: exit $got, want $want"; return 1; }
}
asked() { grep -qxF -- "$1" "$LOG"; }
traces=(bash "$work/operator/traces.sh")
id=main-20260928t120000z

cp "$work/traced.tar.zst" "$work/raw.tar.zst"
if run 0 "fetch and summarize" "${traces[@]}" "$id" --out "$work/view"; then
  asked "s3://forge-perf-results-654654381893/raw/main/$id/raw.tar.zst" &&
    cmp -s "$dir/fixtures/traces/traces.jsonl" "$work/view/traces/traces.jsonl" &&
    [ -f "$work/view/traces/collector.log" ] && asked ./run/traces &&
    grep -q "^8 spans in 2 traces over 39.00s" "$work/out" && grep -q "^ingot  *bucket.lock  *2 " "$work/out" &&
    ! grep -q '^docker$' "$LOG" &&
    echo "ok: traces.sh copies raw/<box>/<run_id>/raw.tar.zst, extracts only traces/ and prints the summary" ||
    fail "fetch and summarize"
fi
echo stale >"$work/view/traces/stale"
run 0 "a second fetch" env FORGE_PERF_RESULTS_BUCKET=other-bucket bash "$work/operator/traces.sh" "$id" --out "$work/view" &&
  asked "s3://other-bucket/raw/main/$id/raw.tar.zst" && [ ! -e "$work/view/traces/stale" ] &&
  echo "ok: FORGE_PERF_RESULTS_BUCKET names the bucket, and a second fetch replaces traces/" || fail "second fetch"
run 1 "a malformed run ID" "${traces[@]}" 'main;x-20260928t120000z' --out "$work/view" && [ ! -s "$LOG" ] &&
  echo "ok: a malformed run ID is refused before any call" || fail "malformed run ID"
run 1 "an unknown option" "${traces[@]}" "$id" --outdir "$work/view" && [ ! -s "$LOG" ] &&
  echo "ok: an unknown option is refused before any call" || fail "unknown option"

rm "$work/raw.tar.zst"
run 1 "no access to raw/" "${traces[@]}" "$id" --out "$work/denied" && grep -q "raw_missing run, or older than 180 days" "$work/out" && grep -q "operator credentials" "$work/out" &&
  [ ! -e "$work/denied" ] &&
  echo "ok: a copy that fails names the missing tarball and the credentials raw/ needs, and writes nothing" || fail "no access"
cp "$work/untraced.tar.zst" "$work/raw.tar.zst"
run 1 "an untraced run" "${traces[@]}" "$id" --out "$work/untraced" && grep -q "was not traced" "$work/out" &&
  [ ! -e "$work/untraced" ] &&
  echo "ok: a tarball without traces/ is an untraced run" || fail "untraced"

cp "$work/traced.tar.zst" "$work/raw.tar.zst"
if run 0 "--jaeger" env TRACES_JAEGER_WAIT_SECONDS=5 bash "$work/operator/traces.sh" "$id" --out "$work/view" --jaeger; then
  asked "jaegertracing/jaeger@$digest" && asked "127.0.0.1:16686:16686" && asked "127.0.0.1:4318:4318" &&
    asked "forge-perf-jaeger" &&
    # The image declares VOLUME /tmp; a tmpfs there leaves no anonymous volume behind.
    asked "--tmpfs" && asked "/tmp" &&
    [ "$(grep -cxF http://127.0.0.1:4318/v1/traces "$LOG")" -eq 5 ] &&
    grep -q "Jaeger took 4 of 5 lines" "$work/out" && grep -q "Jaeger refused 1" "$work/out" &&
    grep -qxF "Jaeger UI: http://127.0.0.1:16686/" "$work/out" &&
    echo "ok: --jaeger runs the pinned image on 127.0.0.1, POSTs each line to /v1/traces and prints the UI" ||
    fail "--jaeger"
fi
touch "$work/ui-down"
run 1 "Jaeger that does not answer" env TRACES_JAEGER_WAIT_SECONDS=0 bash "$work/operator/traces.sh" "$id" \
  --out "$work/view" --jaeger && grep -q "did not answer" "$work/out" && grep -q "docker rm -f forge-perf-jaeger" "$work/out" && ! grep -q "/v1/traces" "$LOG" &&
  echo "ok: --jaeger gives up when the UI does not answer, before loading anything" || fail "Jaeger down"
rm "$work/ui-down"

pinned="$(awk '$1 == "JAEGER_IMAGE"' "$dir/images.lock")"
[[ "$pinned" =~ ^JAEGER_IMAGE\ +jaegertracing/jaeger:2\.[0-9]+\.[0-9]+\ +sha256:[0-9a-f]{64}$ ]] &&
  echo "ok: images.lock pins a Jaeger v2 release by digest" ||
  { echo "FAIL: images.lock has no well-formed Jaeger v2 line" && failures=$((failures + 1)); }

[ "$failures" -eq 0 ] || exit 1
echo "traces_test: all passed"
