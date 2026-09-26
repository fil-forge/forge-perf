#!/usr/bin/env bash
# Behavior of poll.sh and status.sh against a stubbed resolver: curl answers
# GHCR from $D/digests (repo digest per line), git answers ls-remote from
# $D/heads, aws keeps the heartbeat, and flock reports a run going while
# $D/running exists. Runs in skip mode, so a dispatch is the logged
# `host-op skipped: systemctl start --no-block forge-perf-run.service`.
#
# SC2015: `a && b || fail` is intended; fail runs when either check fails.
# shellcheck disable=SC2015
set -euo pipefail

host="$(cd "$(dirname "$0")/.." && pwd -P)"
repo="$(cd "$host/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/poll-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export D="$work/d"
mkdir -p "$work/bin"
unset INVOCATION_ID FORGE_PERF_LOCK_HELD SMELT_REF SQ_PIN

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *169.254.169.254*) exit 7 ;;
  *ghcr.io/token*) [ ! -e "$D/ghcr-down" ] || exit 22; echo '{"token": "anon"}' ;;
  *ghcr.io/v2/*)
    repo="${url#*ghcr.io/v2/}" repo="${repo%/manifests/*}"
    d="$(awk -v r="$repo" '$1 == r { print $2 }' "$D/digests")"
    [ -n "$d" ] || exit 22
    printf 'HTTP/2 200\r\ncontent-type: application/vnd.oci.image.index.v1+json\r\ndocker-content-digest: %s\r\n\r\n' "$d" ;;
  *) exit 22 ;;
esac
STUB
cat >"$work/bin/git" <<'STUB'
#!/usr/bin/env bash
for a; do
  if [ "$a" = ls-remote ]; then
    echo "git $*" >>"$D/git.log"
    url="${@: -2:1}"
    sha="$(awk -v u="$url" '$1 == u { print $2 }' "$D/heads")"
    [ -n "$sha" ] || exit 128
    printf '%s\trefs/heads/main\n' "$sha"
    exit 0
  fi
done
exec /usr/bin/git "$@"
STUB
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$D/aws.log"
case " $* " in
  *" put-object "*heartbeat.json*)
    [ ! -e "$D/s3-down" ] || exit 1
    while [ "$1" != --body ]; do shift; done
    cp "$2" "$D/heartbeat.json" ;;
  *" s3 cp "* | *" put-object "*) [ ! -e "$D/s3-down" ] ;;
  *) echo "aws stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
# flock -n FILE true: the run lock is busy while $D/running exists.
cat >"$work/bin/flock" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *run.lock*) [ ! -e "$D/running" ] ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" FORGE_PERF_HOST_OPS=skip

fail() {
  echo "FAIL: $*" >&2
  sed 's/^/  | /' "$work/out" >&2 || true
  exit 1
}
digest() { printf 'sha256:%064d' "$1"; }
state="$work/box/state"

# A fresh box: a checkout copy with its own config, one digest per image.
setup() {
  rm -rf "$work/box" "$D"
  mkdir -p "$D" "$work/box/checkout" "$work/box/state" "$work/box/outbox" "$work/box/run"
  cp -R "$repo/config" "$work/box/checkout/"
  # The fixture box pins the harness, so these cases never look up harness
  # main; the case that unpins it below clears the pin again.
  sed -i.bak 's/^SQ_PIN=.*/SQ_PIN=5cfeaf390803809acd089614ee2aaa5cf3a4153d/' "$work/box/checkout/config/harness.conf"
  rm "$work/box/checkout/config/harness.conf.bak"
  /usr/bin/git -C "$work/box/checkout" init -q
  /usr/bin/git -C "$work/box/checkout" -c user.name=t -c user.email=t@t add -A
  /usr/bin/git -C "$work/box/checkout" -c user.name=t -c user.email=t@t commit -qm config
  sed 's/#.*//' "$repo/config/images.tracked" | awk 'NF == 2 { r = $2; sub(/^ghcr.io\//, "", r); sub(/:.*/, "", r);
    printf "%s sha256:%064d\n", r, 1 }' >"$D/digests"
  echo "https://github.com/fil-forge/smelt.git $(printf '%040d' 5)" >"$D/heads"
  cat >"$work/box/box.conf" <<EOF
FORGE_PERF_BOX_ID=test
FORGE_PERF_CHECKOUT=$work/box/checkout
FORGE_PERF_RESULTS_BUCKET=test-results
EOF
}
# ingot N: publish a new ingot digest.
ingot() { sed -i.bak "s|^fil-forge/ingot .*|fil-forge/ingot $(digest "$1")|" "$D/digests"; }
poll() {
  local want="$1"
  shift
  local got=0
  env FORGE_PERF_BOX_CONF="$work/box/box.conf" FORGE_PERF_STATE_DIR="$state" \
    FORGE_PERF_OUTBOX="$work/box/outbox" FORGE_PERF_RUNTIME="$work/box/run" \
    bash "$host/poll.sh" "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "poll.sh $* exited $got, wanted $want"
}
status() {
  env FORGE_PERF_BOX_CONF="$work/box/box.conf" FORGE_PERF_STATE_DIR="$state" \
    FORGE_PERF_OUTBOX="$work/box/outbox" FORGE_PERF_RUNTIME="$work/box/run" \
    bash "$host/status.sh" "$@" >"$work/out" 2>&1 || fail "status.sh $* failed"
}
dispatched() { grep -q "host-op skipped: systemctl start --no-block forge-perf-run.service" "$work/out"; }
pending() { jq -r "$1" "$state/pending.json"; }
beat() { jq -r "$1" "$D/heartbeat.json"; }
# What run.sh does when it takes the pending run: last-started, no pending.
start_run() { jq .set "$state/pending.json" >"$state/last-started.json" && rm "$state/pending.json"; }

setup
poll 0
dispatched || fail "no dispatch"
[ "$(pending '"\(.kind) \(.superseded) \(.set.harness.pinned) \(.set.harness.main)"')" = "trigger 0 true null" ] ||
  fail "pending $(cat "$state/pending.json")"
[ "$(pending '.set.images | length')" = "$(sed 's/#.*//' "$repo/config/images.tracked" | awk 'NF == 2' | wc -l | tr -d ' ')" ] ||
  fail "images $(pending .set.images)"
[ "$(pending '.set.smelt')" = "$(sed -n 's/^SMELT_REF=//p' "$repo/config/smelt.conf")" ] || fail "smelt from SMELT_REF"
[ "$(beat '"\(.box) \(.state) \(.poll_failures) \(.pending_kind)"')" = "test idle 0 trigger" ] ||
  fail "heartbeat $(cat "$D/heartbeat.json")"
grep -q -- "--key published/test/heartbeat.json" "$D/aws.log" || fail "heartbeat key"
echo "ok: a new set is pending, starts at once, and the heartbeat says idle"

start_run
touch "$D/running"
for n in 2 3 4; do
  ingot "$n"
  poll 0
  dispatched && fail "dispatched during a run"
done
[ "$(pending '"\(.kind) \(.superseded)"')" = "trigger 2" ] || fail "burst $(cat "$state/pending.json")"
[ "$(pending '.set.images["ghcr.io/fil-forge/ingot:main"]')" = "$(digest 4)" ] || fail "latest set wins"
[ "$(beat .state)" = running ] || fail "state $(beat .state)"
poll 0
[ "$(pending .superseded)" = 2 ] || fail "the same set counted again"
echo "ok: three sets during a run leave one pending, the newest, with superseded 2"

poll 0 --nightly
[ "$(pending '"\(.kind) \(.superseded)"')" = "nightly 2" ] || fail "nightly $(cat "$state/pending.json")"
ingot 5
poll 0
[ "$(pending '"\(.kind) \(.superseded)"')" = "nightly 3" ] || fail "nightly keeps its kind $(cat "$state/pending.json")"
rm "$D/running"
poll 0
dispatched || fail "no dispatch once idle"
echo "ok: the nightly absorbs a pending trigger and keeps its kind for a newer set"

setup
poll 0
start_run
jq -n --slurpfile s "$state/last-started.json" '{run_id: "test-1", kind: "trigger", set: $s[0], superseded: 0,
  attempt: 0, previous_started: null, reasons: ["stack_boot_failed"]}' >"$state/last-run.json"
poll 0
[ ! -e "$state/pending.json" ] && ! dispatched || fail "a failed set was started again"
[ ! -e "$state/last-run.json" ] || fail "last-run.json left"
poll 0 --nightly
[ "$(pending .kind)" = nightly ] && dispatched || fail "the nightly did not start the failed set"
echo "ok: a failed set waits for the nightly"

setup
poll 0
start_run
cp "$state/last-started.json" "$work/set.json"
for attempt in 0 1 2 3; do
  jq -n --slurpfile s "$work/set.json" --argjson a "$attempt" '{run_id: "test-\($a)", kind: "trigger", set: $s[0],
    superseded: 0, attempt: $a, previous_started: null, reasons: ["image_pull_failed", "setup_failed"]}' \
    >"$state/last-run.json"
  poll 0
  if [ "$attempt" -lt 3 ]; then
    [ "$(pending .attempt)" = $((attempt + 1)) ] || fail "attempt $attempt: $(cat "$state/pending.json")"
    [ "$(pending '.not_before - now | . > 800 and . <= 900')" = true ] || fail "not 15 minutes"
    [ ! -e "$state/last-started.json" ] || fail "the set stayed in last-started.json"
    ! dispatched || fail "a retry started before its time"
    jq '.not_before = 0' "$state/pending.json" >"$work/p" && mv "$work/p" "$state/pending.json"
    poll 0
    dispatched || fail "retry $((attempt + 1)) did not start"
    start_run
  else
    [ ! -e "$state/pending.json" ] || fail "a fourth retry"
    grep -q "after 3 retries" "$work/out" || fail "no message after the third retry"
    [ -e "$state/last-started.json" ] || fail "the set left last-started.json"
  fi
done
echo "ok: an image_pull_failed set is retried three times, 15 minutes apart"

setup
poll 0
start_run
jq '{run_id: "x", kind: "nightly", set: ., superseded: 0, attempt: 0, reasons: ["s3_unreachable"]}' \
  "$state/last-started.json" >"$state/last-run.json"
jq '.previous_started = {smelt: "old"}' "$state/last-run.json" >"$work/p" && mv "$work/p" "$state/last-run.json"
poll 0
[ "$(jq -r .smelt "$state/last-started.json")" = old ] || fail "last-started not put back"
[ "$(pending '"\(.kind) \(.superseded) \(.attempt)"')" = "nightly 0 1" ] || fail "retry $(cat "$state/pending.json")"
ingot 7
poll 0
[ "$(pending '"\(.kind) \(.superseded) \(.attempt) \(.not_before)"')" = "nightly 1 null null" ] ||
  fail "newer set $(cat "$state/pending.json")"
dispatched || fail "the newer set waited"
echo "ok: a retry keeps the nightly kind, and a newer set replaces it at the next pass"

setup
status hold
ingot 8
poll 0
! dispatched || fail "a held box dispatched"
[ -e "$state/pending.json" ] || fail "no pending while held"
[ "$(beat .state)" = held ] || fail "state $(beat .state)"
status
grep -q '^hold:' "$work/out" && grep -q '^pending.json: {"kind":"trigger"' "$work/out" || fail "status output"
status hold --wait-idle
grep -q '^idle$' "$work/out" || fail "wait-idle"
status release
[ ! -e "$state/hold" ] || fail "hold left"
poll 0
dispatched || fail "no dispatch after release"
echo "ok: a held box dispatches nothing, and release lets the pending run start"

setup
sed -i.bak 's/^WORKERS=.*/WORKERS=/' "$work/box/checkout/config/settings/local.env"
poll 0
! dispatched || fail "dispatched with WORKERS empty"
grep -q "WORKERS is empty" "$work/out" || fail "no WORKERS message"
echo "ok: no dispatch while WORKERS is empty"

setup
touch "$D/ghcr-down"
poll 1
poll 1
[ ! -e "$state/pending.json" ] || fail "pending written without a set"
[ "$(beat .poll_failures)" = 2 ] || fail "poll_failures $(beat .poll_failures)"
rm "$D/ghcr-down"
poll 0
[ "$(beat .poll_failures)" = 0 ] || fail "poll_failures not reset"
echo "ok: a failed resolution writes no pending and counts in the heartbeat"

setup
sed -i.bak 's/^SQ_PIN=.*/SQ_PIN=/' "$work/box/checkout/config/harness.conf"
sed -i.bak 's/^SMELT_REF=.*/SMELT_REF=/' "$work/box/checkout/config/smelt.conf"
echo "https://github.com/fil-one/storage-qualification.git $(printf '%040d' 6)" >>"$D/heads"
FORGE_PERF_HARNESS_AUTH=none poll 0
[ "$(pending '"\(.set.smelt) \(.set.harness.sha) \(.set.harness.pinned) \(.set.harness.main)"')" = \
  "$(printf '%040d' 5) $(printf '%040d' 6) false $(printf '%040d' 6)" ] || fail "heads $(pending .set.harness)"
echo "ok: without the pins, smelt and harness main come from git ls-remote"

setup
poll 0
mv "$state/pending.json" "$state/pending.json.rejected"
poll 0
[ ! -e "$state/pending.json" ] || fail "a rejected set came back"
echo "ok: a set run.sh rejected is not pending again"

setup
poll 0
start_run
echo '{"run_id": "test-9"}' >"$work/box/outbox/test-9.json"
touch "$D/running"
poll 0
[ -e "$work/box/outbox/test-9.json" ] || fail "flushed during a run"
rm "$D/running"
poll 0
[ ! -e "$work/box/outbox/test-9.json" ] || fail "outbox not flushed"
grep -q -- "--key published/test/test-9.json" "$D/aws.log" || fail "record not uploaded"
echo "ok: the outbox is flushed between runs"

echo "poll: all tests passed"
