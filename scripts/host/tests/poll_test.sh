#!/usr/bin/env bash
# Behavior of poll.sh and status.sh against a stubbed resolver: curl answers
# GHCR from $D/digests (repo digest per line) and a manifest by digest from
# $D/manifests, git answers ls-remote from $D/heads, aws keeps the heartbeat
# and serves the requests bucket from $D/requests/ (status files land in
# $D/status/), and flock reports a run going while $D/running exists and an
# experiment while $D/experimenting does. Runs in skip mode, so a dispatch is
# the logged `host-op skipped: systemctl start --no-block forge-perf-run.service`
# and a sleeping box is the logged `host-op skipped: systemctl poweroff`. The
# sleep cases set the uptime with UPTIME and the clock wake_at is counted from
# with AT. date answers `-u +%F` with a later day from its second call on while
# $D/midnight exists, which is a pass that crosses midnight UTC.
#
# SC2015: `a && b || fail` is intended; fail runs when either check fails.
# shellcheck disable=SC2015
set -euo pipefail

host="$(cd "$(dirname "$0")/.." && pwd -P)"
repo="$(cd "$host/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/poll-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# No background gc or maintenance in the fixture repositories, which setup
# removes (Apple git 2.54 otherwise races the rm).
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export D="$work/d"
mkdir -p "$work/bin"
unset INVOCATION_ID FORGE_PERF_LOCK_HELD SMELT_REF SQ_PIN

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *169.254.169.254*) exit 7 ;;
  *ghcr.io/token*)
    [ ! -e "$D/ghcr-down" ] || exit 22
    # status.sh hold, run while the pass resolves.
    [ ! -e "$D/hold-mid-pass" ] || cp "$D/hold-mid-pass" "$FORGE_PERF_STATE_DIR/hold"
    echo '{"token": "anon"}' ;;
  *ghcr.io/v2/*/manifests/sha256:*)
    [ ! -e "$D/ghcr-down" ] || exit 7
    repo="${url#*ghcr.io/v2/}" repo="${repo%/manifests/*}"
    if grep -qxF "$repo ${url##*/}" "$D/manifests" 2>/dev/null; then echo 200; else echo 404; fi ;;
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
# A hold or a manual run that arrives after the pass chose what to start.
case " $* " in
  *" rev-parse "*)
    [ ! -e "$D/hold-late" ] || cp "$D/hold-late" "$FORGE_PERF_STATE_DIR/hold"
    [ ! -e "$D/run-late" ] || touch "$D/running" ;;
esac
exec /usr/bin/git "$@"
STUB
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$D/aws.log"
key() { while [ "$1" != --key ]; do shift; done; echo "$2"; }
case " $* " in
  *" --bucket test-requests "*)
    [ ! -e "$D/requests-down" ] || exit 255
    case " $* " in
      *" list-objects-v2 "*)
        python3 -c '
import datetime, json, os, sys
d = sys.argv[1]
out = [{"Key": "requests/" + n, "Size": os.path.getsize(os.path.join(d, n)),
        "LastModified": datetime.datetime.fromtimestamp(os.path.getmtime(os.path.join(d, n)),
                                                        datetime.timezone.utc).isoformat()}
       for n in sorted(os.listdir(d))] if os.path.isdir(d) else []
print(json.dumps({"Contents": out} if out else {}))' "$D/requests" ;;
      *" get-object "*) [ ! -e "$D/get-down" ] || exit 1; k="$(key "$@")"; cp "$D/requests/${k#requests/}" "${!#}" ;;
      *" delete-object "*) k="$(key "$@")"; rm -f "$D/requests/${k#requests/}"; echo "$k" >>"$D/deleted" ;;
      *" put-object "*)
        [ ! -e "$D/status-down" ] || exit 1
        k="$(key "$@")"
        while [ "$1" != --body ]; do shift; done
        mkdir -p "$D/status"
        cp "$2" "$D/status/${k#status/}"
        echo "$k" >>"$D/status.log" ;;
      *) echo "aws stub: unexpected $*" >&2; exit 1 ;;
    esac ;;
  *" put-object "*heartbeat.json*)
    [ ! -e "$D/s3-down" ] || exit 1
    while [ "$1" != --body ]; do shift; done
    cp "$2" "$D/heartbeat.json"
    # A hold or a manual run that arrives while the heartbeat goes up.
    [ ! -e "$D/hold-at-upload" ] || cp "$D/hold-at-upload" "$FORGE_PERF_STATE_DIR/hold"
    [ ! -e "$D/run-at-upload" ] || touch "$D/running" ;;
  *" s3 cp "* | *" put-object "*) [ ! -e "$D/s3-down" ] && [ ! -e "$D/outbox-down" ] ;;
  *) echo "aws stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
# flock -n FILE true: the run lock is busy while $D/running exists.
cat >"$work/bin/flock" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *run.lock*) [ ! -e "$D/running" ] ;;
  *experiment.lock*) [ ! -e "$D/experimenting" ] ;;
  *) exit 0 ;;
esac
STUB
cat >"$work/bin/date" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-u +%F" ] && [ -e "$D/midnight" ]; then
  if [ -s "$D/midnight" ]; then
    echo 2099-01-01
    exit 0
  fi
  echo seen >"$D/midnight"
fi
exec /bin/date "$@"
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
  # The fixture box pins the harness and smelt, so these cases never look up
  # either main; the case that unpins them below clears the pins again.
  sed -i.bak 's/^SQ_PIN=.*/SQ_PIN=5cfeaf390803809acd089614ee2aaa5cf3a4153d/' "$work/box/checkout/config/harness.conf"
  sed -i.bak 's/^SMELT_REF=.*/SMELT_REF=21940118fa1863e1f56f950959ad54e0d4d032c3/' "$work/box/checkout/config/smelt.conf"
  # Sleeping is off unless a test turns it on, whatever config/launch.conf says.
  sed -i.bak 's/^SLEEP_WHEN_IDLE=.*/SLEEP_WHEN_IDLE=0/' "$work/box/checkout/config/launch.conf"
  rm "$work/box/checkout/config/harness.conf.bak" "$work/box/checkout/config/smelt.conf.bak" \
    "$work/box/checkout/config/launch.conf.bak"
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
FORGE_PERF_REQUESTS_BUCKET=test-requests
EOF
}
# ingot N: publish a new ingot digest.
ingot() { sed -i.bak "s|^fil-forge/ingot .*|fil-forge/ingot $(digest "$1")|" "$D/digests"; }
poll() {
  local want="$1"
  shift
  local got=0
  # Midday UTC, outside the hour around the nightly run, unless HHMM says.
  env FORGE_PERF_UTC_HHMM="${HHMM:-1200}" FORGE_PERF_BOX_CONF="$work/box/box.conf" FORGE_PERF_STATE_DIR="$state" \
    FORGE_PERF_OUTBOX="$work/box/outbox" FORGE_PERF_RUNTIME="$work/box/run" \
    FORGE_PERF_UPTIME_S="${UPTIME:-3600}" \
    FORGE_PERF_UTC_EPOCH="$(jq -n --arg t "${AT:-2026-10-01T12:00:00Z}" '$t | fromdate')" \
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
[ "$(pending '.set.smelt')" = "$(sed -n 's/^SMELT_REF=//p' "$work/box/checkout/config/smelt.conf")" ] || fail "smelt from SMELT_REF"
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
echo '{"at": "2026-10-01T12:00:00Z"}' >"$D/hold-mid-pass"
poll 0
[ -e "$state/hold" ] || fail "the stub set no hold"
! dispatched || fail "a hold set during resolution still dispatched"
[ -e "$state/pending.json" ] && [ "$(beat .state)" = held ] || fail "pending or state $(beat .state)"
echo "ok: a hold set while the pass resolves stops that pass's dispatch"

setup
rm "$work/box/checkout/config/settings/local.env"
poll 0
! dispatched || fail "dispatched without a settings file"
grep -q "no settings file for instance type local" "$work/out" || fail "no settings message"
[ "$(beat .state)" = idle ] || fail "no heartbeat without a settings file"
echo "ok: without a settings file the pending run waits and the heartbeat goes up"

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

# The update path, driven in skip mode: the checkout's origin answers from
# $D/heads, and systemctl is-active reports forge-perf-update as stopped.
updating() { grep -q "host-op skipped: systemd-run --unit forge-perf-update" "$work/out"; }
setup
head="$(/usr/bin/git -C "$work/box/checkout" rev-parse HEAD)"
echo "origin $head" >>"$D/heads"
FORGE_PERF_POLL_UPDATES=1 poll 1
updating && ! dispatched || fail "a checkout without updated-rev dispatched instead of updating"
[ "$(beat .poll_failures)" = 1 ] || fail "update failure not in the heartbeat: $(beat .poll_failures)"
FORGE_PERF_POLL_UPDATES=1 poll 1
updating && ! dispatched || fail "the second pass did not start update.sh again"
[ "$(beat .poll_failures)" = 2 ] || fail "update failures did not add up: $(beat .poll_failures)"
echo "ok: while update.sh has not finished for HEAD, each pass reruns it, starts no run, and counts a failure"
printf '%s\n' "$head" >"$state/updated-rev"
FORGE_PERF_POLL_UPDATES=1 poll 0
dispatched && ! updating || fail "no dispatch once updated-rev matches HEAD"
[ "$(beat .poll_failures)" = 0 ] && [ "$(cat "$state/update-failures")" = 0 ] || fail "update failures not cleared"
echo "ok: once updated-rev matches HEAD the pending run starts and the count clears"
start_run
sed -i.bak "s|^origin .*|origin $(printf '%040d' 9)|" "$D/heads"
ingot 2
FORGE_PERF_POLL_UPDATES=1 poll 0
updating && ! dispatched || fail "origin moved and the pass did not update"
[ "$(beat .poll_failures)" = 0 ] || fail "a moved origin counted as a failure"
echo "ok: when origin moves the pass starts update.sh, not the run"

setup
poll 0
start_run
ingot 7
jq -n --slurpfile s "$state/last-started.json" '{kind: "campaign", set: $s[0], superseded: 0, workers: "16"}' \
  >"$state/pending.json"
cp "$state/pending.json" "$work/campaign.json"
echo '{"at": "2026-10-01T12:00:00Z"}' >"$state/hold"
poll 0 --nightly
cmp -s "$state/pending.json" "$work/campaign.json" || fail "the poller replaced a campaign's run: $(cat "$state/pending.json")"
jq -n --slurpfile s "$work/campaign.json" '{run_id: "test-c", kind: "campaign", set: $s[0].set, superseded: 0,
  attempt: 0, previous_started: null, reasons: ["image_pull_failed"]}' >"$state/last-run.json"
rm "$state/pending.json"
poll 0
[ ! -e "$state/last-run.json" ] || fail "a campaign's last-run.json left"
[ "$(pending '"\(.kind) \(.attempt)"')" = "trigger null" ] || fail "after the campaign $(cat "$state/pending.json")"
echo "ok: the poller leaves a campaign's run alone and never retries one"


# --- experiments -------------------------------------------------------------------
COMMIT=0123456789abcdef0123456789abcdef01234567
BRANCH="sha256:$(printf 'b%.0s' {1..64})"
req_id() { echo "ingot-pr$1-${COMMIT:0:12}-$2"; }
# request PR N [JQ]: a request for ingot's pull request PR, the Nth oldest in
# the bucket, edited by JQ.
request() {
  local id
  id="$(req_id "$1" "$2")"
  mkdir -p "$D/requests"
  jq -n --arg id "$id" --argjson pr "$1" --arg c "$COMMIT" --arg d "$BRANCH" '{schema: "forge-perf.request/v1",
    id: $id, service: "ingot", image: "ghcr.io/fil-forge/ingot", digest: $d, tag: "pr-\($pr)-\($c[:7])",
    commit: $c, repository: "fil-forge/ingot", pr: $pr, requested_by: "someone",
    requested_at: "2026-10-01T12:00:00Z", pairs: 1}' | jq "${3:-.}" >"$D/requests/$id.json"
  touch -t "20261001$(printf '%04d' "$2")" "$D/requests/$id.json"
}
got() { jq -r "$2" "$D/status/$1.json" 2>/dev/null; }
started_exp() { grep -q "host-op skipped: systemctl start --no-block forge-perf-experiment.service" "$work/out"; }
# idle: a fresh box whose main set has run, so nothing is pending.
idle() {
  setup
  poll 0
  start_run
  echo "fil-forge/ingot $BRANCH" >"$D/manifests"
}
id1="$(req_id 123 1)" id2="$(req_id 124 2)" id3="$(req_id 125 3)"

idle
touch "$D/running"
request 123 1
request 124 2 '.pairs = 3'
request 125 3 '.digest = "sha256:" + ("c" * 64)'
poll 0
[ "$(got "$id1" '"\(.state) \(.position) \(.pairing_id)"')" = "queued 1 exp-$id1" ] || fail "id1 $(cat "$D/status/$id1.json")"
[ "$(got "$id2" '"\(.state) \(.reason)"')" = "refused pairs must be 1 or 2" ] || fail "id2 $(cat "$D/status/$id2.json")"
[ "$(got "$id3" .reason)" = "sha256:$(printf 'c%.0s' {1..64}) cannot be pulled anonymously from ghcr.io/fil-forge/ingot" ] ||
  fail "id3 $(got "$id3" .)"
[ -e "$D/requests/$id1.json" ] && [ ! -e "$D/requests/$id2.json" ] && [ ! -e "$D/requests/$id3.json" ] ||
  fail "refused requests left, or the queued one deleted: $(ls "$D/requests")"
! started_exp || fail "an experiment started during a run"
[ "$(beat .experiments_queued)" = 1 ] || fail "heartbeat $(cat "$D/heartbeat.json")"
before="$(grep -c "status/$id1.json" "$D/status.log")"
poll 0
[ "$(grep -c "status/$id1.json" "$D/status.log")" = "$before" ] || fail "an unchanged status was sent again"
echo "ok: requests are checked and queued oldest first; the rest are refused with a reason and deleted"

idle
touch "$D/running"
request 123 1
touch "$D/ghcr-down"
poll 1
[ ! -e "$D/status/$id1.json" ] && [ -e "$D/requests/$id1.json" ] || fail "a request refused while GHCR was down"
rm "$D/ghcr-down"
poll 0
[ "$(got "$id1" .state)" = queued ] || fail "not queued once GHCR answered"
rm "$D/running"
touch "$D/ghcr-down"
poll 1
! started_exp && grep -q "main's set did not resolve" "$work/out" || fail "an experiment started without main's set"
echo "ok: a request waits while GHCR does not answer, and no experiment starts without main's set"

idle
request 123 1
request 124 2
ingot 9
poll 0
dispatched && ! started_exp || fail "the live run did not go first"
[ "$(got "$id1" .position) $(got "$id2" .position)" = "1 2" ] || fail "positions"
start_run
poll 0
started_exp || fail "the oldest experiment did not start"
jq -e --arg b "$BRANCH" --arg m "$(digest 9)" --arg id "$id1" '.id == $id and .order == ["main", "branch"]
  and .sets.main.images["ghcr.io/fil-forge/ingot:main"] == $m and .sets.branch.images["ghcr.io/fil-forge/ingot:main"] == $b
  and (.sets.main.images | del(.["ghcr.io/fil-forge/ingot:main"])) == (.sets.branch.images | del(.["ghcr.io/fil-forge/ingot:main"]))
  and .overrides["ghcr.io/fil-forge/ingot:main"].ref == "pr-123-0123456"
  and .experiment == {request_id: $id, service: "ingot", repository: "fil-forge/ingot", pr: 123,
    commit: "0123456789abcdef0123456789abcdef01234567"}' "$state/experiment.json" >/dev/null ||
  fail "plan $(cat "$state/experiment.json")"
jq -e --arg m "$(digest 9)" '.images["ghcr.io/fil-forge/ingot:main"] == $m' "$state/last-started.json" >/dev/null ||
  fail "last-started changed"
[ "$(got "$id2" .position)" = 1 ] || fail "id2 did not move up"
[ ! -e "$state/experiments/queue/$id1.json" ] && grep -q "^$(date -u +%F) $id1$" "$state/experiments/started" ||
  fail "the start was not logged"
echo "ok: a pending live run goes first, then the oldest experiment starts on main's set with one digest swapped"

touch "$D/experimenting"
ingot 10
poll 0
! dispatched && ! started_exp || fail "a run started inside an experiment"
[ "$(beat .state)" = running ] && [ "$(pending .kind)" = trigger ] || fail "state $(beat .state)"
rm "$D/experimenting"
poll 0
[ "$(got "$id1" '"\(.state) \(.reason)"')" = "failed the experiment stopped before it finished" ] ||
  fail "stale experiment $(got "$id1" .)"
[ ! -e "$state/experiment.json" ] && [ ! -e "$D/requests/$id1.json" ] && dispatched ||
  fail "the stopped experiment was not closed, or the live run did not start"
request 123 1
start_run
poll 0
[ ! -e "$D/requests/$id1.json" ] && [ "$(got "$id1" .state)" = failed ] &&
  [ "$(jq -r .id "$state/experiment.json")" = "$id2" ] || fail "a finished request ran again"
echo "ok: no live run starts inside an experiment; one left behind ends failed; a finished request never runs again"

idle
request 123 1
request 124 2
poll 0
started_exp || fail "the oldest experiment did not start"
touch "$D/status-down"
poll 0
! started_exp && [ "$(jq -r .id "$state/experiment.json")" = "$id1" ] &&
  grep -q "earlier experiment is not settled" "$work/out" || fail "an experiment started over an unsettled one"
rm "$D/status-down"
poll 0
[ "$(got "$id1" .state)" = failed ] && started_exp && [ "$(jq -r .id "$state/experiment.json")" = "$id2" ] ||
  fail "the unsettled experiment was not closed before the next started"
echo "ok: no experiment starts while an earlier one's failed status has not gone up"

idle
request 123 1
HHMM=0300 poll 0
! started_exp && grep -q "between 02:30 and 03:30 UTC" "$work/out" || fail "started near the nightly run"
HHMM=0229 poll 0
started_exp || fail "did not start at 02:29"
echo "ok: no experiment starts between 02:30 and 03:30 UTC"

idle
request 123 1
for i in 1 2 3 4; do echo "$(date -u +%F) earlier-$i"; done >"$state/experiments/started"
poll 0
! started_exp && grep -q "4 experiments started today" "$work/out" || fail "the daily cap did not hold"
status hold
sed -i.bak '1d' "$state/experiments/started"
poll 0
! started_exp || fail "a held box started an experiment"
status release
poll 0
started_exp || fail "no start after release"
[ "$(wc -l <"$state/experiments/started" | tr -d ' ')" = 4 ] || fail "started log"
echo "ok: four experiments a UTC day at most, and none while the box is held"

idle
mkdir -p "$D/requests"
echo '{}' >"$D/requests/NOT-AN-ID.json"
poll 0
grep -qx "requests/NOT-AN-ID.json" "$D/deleted" || fail "a malformed key stayed"
echo "ok: an object that is not requests/<id>.json is deleted"


# --- sleeping ----------------------------------------------------------------------
VECTOR=fcc24b38e5e7d98d5194106d971053bdcd015e3ba3cea03c4ec7dffa7dcf203c
powered_off() { grep -q "host-op skipped: systemctl poweroff" "$work/out"; }
# up REASON [STATE]: the pass powered nothing off, logged REASON as why, and
# its heartbeat says STATE (idle unless given) with no wake_at.
up() {
  ! powered_off || fail "powered off; wanted to stay up: $1"
  grep -q "^poll: staying up: $1" "$work/out" || fail "no 'staying up: $1'"
  [ "$(beat '"\(.state) \(.wake_at)"')" = "${2:-idle} null" ] || fail "heartbeat $(cat "$D/heartbeat.json")"
}
# asleep WAKE_AT: the pass put the box to sleep until WAKE_AT.
asleep() {
  powered_off || fail "not powered off"
  grep -qx "poll: idle; asleep until $1" "$work/out" || fail "no 'asleep until $1'"
  [ "$(beat '"\(.state) \(.wake_at) \(.run_id) \(.run_started_at) \(.poll_failures)"')" = "asleep $1 null null 0" ] ||
    fail "heartbeat $(cat "$D/heartbeat.json")"
}
# sleepy: an idle box with SLEEP_WHEN_IDLE=1.
sleepy() {
  idle
  sed -i.bak 's/^SLEEP_WHEN_IDLE=.*/SLEEP_WHEN_IDLE=1/' "$work/box/checkout/config/launch.conf"
  grep -qx 'SLEEP_WHEN_IDLE=1' "$work/box/checkout/config/launch.conf" || fail "launch.conf has no SLEEP_WHEN_IDLE"
}
seen() { jq -c .seen_keys "$D/heartbeat.json"; }
hash_of() { jq -cSj '.set // . | {smelt, images}' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }

setup
touch "$D/ghcr-down"
poll 1
[ "$(beat '"\(.seen_keys) \(.wake_at)"')" = "[] null" ] || fail "a box with no set: $(cat "$D/heartbeat.json")"
rm "$D/ghcr-down"
poll 0
[ "$(seen)" = "[\"$(hash_of "$state/pending.json")\"]" ] || fail "pending's key $(seen)"
start_run
cp "$repo/calibration/sets/rebaseline-1.json" "$state/last-started.json"
jq '{kind: "trigger", set: ., superseded: 0}' "$repo/calibration/sets/rebaseline-1.json" >"$state/pending.json.rejected"
poll 0
[ "$(seen)" = "$(jq -nc --arg a "$VECTOR" --arg b "$(hash_of "$state/pending.json")" '[$a, $b] | sort')" ] ||
  fail "seen_keys $(seen)"
[ "$(hash_of "$repo/calibration/sets/rebaseline-1.json")" = "$VECTOR" ] || fail "the test's own hash"
echo "ok: seen_keys holds each distinct waker key hash once, and rebaseline-1 hashes to the contract's vector"

idle
poll 0
up "SLEEP_WHEN_IDLE is 0"
[ "$(seen)" = "[\"$(hash_of "$state/last-started.json")\"]" ] || fail "seen_keys $(seen)"
echo "ok: with SLEEP_WHEN_IDLE=0 an idle box stays up"

idle
poll 0
[ "$(beat '"\(.sleep_enabled) \(.up_since)"')" = "false 2026-10-01T11:00:00Z" ] || fail "heartbeat $(cat "$D/heartbeat.json")"
sleepy
UPTIME=599 AT=2026-10-01T00:05:00Z poll 0
up "up 599 s, under SLEEP_MIN_AWAKE_S (600)"
[ "$(beat '"\(.sleep_enabled) \(.up_since)"')" = "true 2026-09-30T23:55:01Z" ] || fail "heartbeat $(cat "$D/heartbeat.json")"
poll 0
asleep 2026-10-02T02:55:00Z
[ "$(beat '"\(.sleep_enabled) \(.up_since)"')" = "true 2026-10-01T11:00:00Z" ] || fail "heartbeat $(cat "$D/heartbeat.json")"
for unknown in x 12.5; do
  sleepy
  UPTIME="$unknown" poll 0
  [ "$(beat '"\(.sleep_enabled) \(.up_since)"')" = "true null" ] || fail "uptime '$unknown': $(cat "$D/heartbeat.json")"
done
sleepy
UPTIME=0599 AT=2026-10-01T00:05:00Z poll 0
up "up 599 s, under SLEEP_MIN_AWAKE_S (600)"
[ "$(beat '"\(.sleep_enabled) \(.up_since)"')" = "true 2026-09-30T23:55:01Z" ] || fail "heartbeat $(cat "$D/heartbeat.json")"
echo "ok: the heartbeat says whether the box may sleep and since when it is up, null when the uptime is unknown, and reads a leading zero as decimal"

sleepy
poll 0
asleep 2026-10-02T02:55:00Z
[ "$(seen)" = "[\"$(hash_of "$state/last-started.json")\"]" ] || fail "seen_keys $(seen)"
AT=2026-10-01T02:44:59Z poll 0
asleep 2026-10-01T02:55:00Z
AT=2026-10-01T03:05:00Z poll 0
asleep 2026-10-02T02:55:00Z
echo "ok: an idle box says asleep with the next 02:55 UTC as wake_at, then powers off"

sleepy
for at in 02:45:00 02:54:59 02:55:00 02:57:00 03:01:00 03:04:59; do
  AT="2026-10-01T${at}Z" poll 0
  up "the nightly run is due"
done
echo "ok: stays up from 02:45 to 03:05 UTC, around the nightly timer"

sleepy
echo 2 >"$state/update-failures"
poll 0
asleep 2026-10-02T02:55:00Z
echo "ok: an asleep heartbeat says poll_failures 0 whatever the count is"

sleepy
: >"$state/pending.json.rejected"
poll 0
asleep 2026-10-02T02:55:00Z
[ "$(seen)" = "[\"$(hash_of "$state/last-started.json")\"]" ] || fail "an empty file added a key: $(seen)"
echo "ok: an empty state file adds nothing to seen_keys"

sleepy
rm "$D/heartbeat.json"
touch "$D/s3-down"
poll 1
! powered_off || fail "powered off without the heartbeat"
grep -q "^poll: staying up: the heartbeat did not go up" "$work/out" || fail "no 'staying up'"
[ ! -e "$D/heartbeat.json" ] && [ "$(jq -r .state "$work/box/run/heartbeat.json")" = asleep ] ||
  fail "the stub took a heartbeat, or the one written was not asleep"
rm "$D/s3-down"
poll 0
asleep 2026-10-02T02:55:00Z
echo "ok: a box whose asleep heartbeat does not go up stays up, and the pass exits 1"

sleepy
touch "$D/running"
poll 0
up "a run is going" running
echo "ok: stays up during a run"

sleepy
echo '{"at": "2026-10-01T12:00:00Z"}' >"$D/run-late"
poll 0
up "a run is going"
echo "ok: stays up when a run started during the pass"

sleepy
ingot 11
poll 0
dispatched || fail "no dispatch"
up "a run is pending"
echo "ok: stays up in the pass that starts a run"

sleepy
request 123 1
poll 0
started_exp || fail "no experiment"
up "an experiment started"
echo "ok: stays up in the pass that starts an experiment"

sleepy
head="$(/usr/bin/git -C "$work/box/checkout" rev-parse HEAD)"
echo "origin $(printf '%040d' 9)" >>"$D/heads"
printf '%s\n' "$head" >"$state/updated-rev"
FORGE_PERF_POLL_UPDATES=1 poll 0
updating || fail "no update"
up "update.sh"
echo "ok: stays up in the pass that starts update.sh"

sleepy
touch "$D/ghcr-down"
poll 1
up "the set did not resolve"
echo "ok: stays up when the set does not resolve"

sleepy
touch "$D/requests-down"
poll 0
up "the requests bucket could not be listed"
echo "ok: stays up when the requests bucket cannot be listed"

sleepy
jq --argjson t "$(($(date +%s) + 900))" '{kind: "trigger", set: ., first_seen_at: "2026-10-01T11:00:00Z", superseded: 0,
  attempt: 1, not_before: $t}' "$state/last-started.json" >"$state/pending.json"
poll 0
! dispatched || fail "a retry started before its time"
up "a run is pending"
echo "ok: stays up while a retry waits for its not_before"

sleepy
request 123 1
poll 0
touch "$D/status-down"
poll 0
[ -e "$state/experiment.json" ] || fail "experiment.json settled"
up "an experiment is not settled"
echo "ok: stays up while an experiment's failed status has not gone up"

sleepy
echo '{"schema": "forge-perf.status/v1", "id": "x", "state": "finished"}' >"$state/experiments/unsent/x.json"
touch "$D/status-down"
poll 0
[ -e "$state/experiments/unsent/x.json" ] || fail "the unsent status went"
up "an experiment's last status has not gone up"
rm "$D/status-down"
poll 0
[ ! -e "$state/experiments/unsent/x.json" ] && [ "$(got x .state)" = finished ] || fail "the unsent status did not go up"
asleep 2026-10-02T02:55:00Z
echo "ok: stays up while an experiment's last status waits in unsent/"

sleepy
request 123 1
touch "$D/get-down"
poll 0
grep -q "cannot read request $id1" "$work/out" && [ -e "$D/requests/$id1.json" ] || fail "the request was read"
up "a request is not checked yet"
echo "ok: stays up while a request could not be read"

sleepy
request 124 2 '.pairs = 3'
touch "$D/status-down"
poll 0
grep -q "refused request $id2" "$work/out" && [ -e "$D/requests/$id2.json" ] || fail "the refusal went through"
up "a request is not checked yet"
rm "$D/status-down"
poll 0
[ "$(got "$id2" .state)" = refused ] || fail "no refusal"
asleep 2026-10-02T02:55:00Z
echo "ok: stays up while a refusal has not gone up, and sleeps once it has"

sleepy
request 123 1
request 124 2
request 125 3
request 126 4
for i in 1 2 3 4; do echo "$(date -u +%F) earlier-$i"; done >"$state/experiments/started"
poll 0
[ "$(beat .experiments_queued)" = 3 ] || fail "experiments_queued $(beat .experiments_queued)"
up "a request is not checked yet"
poll 0
asleep 2026-10-02T00:01:00Z
echo "ok: stays up while a request waits for a later pass to check it"

sleepy
request 123 1
HHMM=0300 poll 0
! started_exp || fail "started near the nightly run"
up "an experiment is queued"
echo "ok: stays up with an experiment queued between 02:30 and 03:30 UTC"

sleepy
request 123 1
for i in 1 2 3 4; do echo "$(date -u +%F) earlier-$i"; done >"$state/experiments/started"
poll 0
asleep 2026-10-02T00:01:00Z
[ "$(beat .experiments_queued)" = 1 ] || fail "experiments_queued $(beat .experiments_queued)"
HHMM=0200 AT=2026-10-01T02:00:00Z poll 0
asleep 2026-10-01T02:55:00Z
echo "ok: with experiments waiting only on the daily cap the box sleeps until 00:01 UTC, or 02:55 when that is sooner"

sleepy
request 123 1
for i in 1 2 3 4; do echo "$(date -u +%F) earlier-$i"; done >"$state/experiments/started"
: >"$D/midnight"
poll 0
grep -q "4 experiments started today" "$work/out" || fail "the cap did not hold"
up "an experiment is queued"
echo "ok: stays up when the daily count was taken before midnight UTC and the pass ends after it"

sleepy
echo '{"run_id": "test-9"}' >"$work/box/outbox/test-9.json"
touch "$D/outbox-down"
poll 0
[ -e "$work/box/outbox/test-9.json" ] || fail "the outbox emptied"
up "the outbox holds files"
rm "$D/outbox-down"
poll 0
asleep 2026-10-02T02:55:00Z
echo "ok: stays up until the outbox is empty"

sleepy
UPTIME=599 poll 0
up "up 599 s, under SLEEP_MIN_AWAKE_S (600)"
UPTIME=600 poll 0
asleep 2026-10-02T02:55:00Z
sed -i.bak 's/^SLEEP_MIN_AWAKE_S=.*/SLEEP_MIN_AWAKE_S=30/' "$work/box/checkout/config/launch.conf"
UPTIME=29 poll 0
up "up 29 s, under SLEEP_MIN_AWAKE_S (30)"
echo "ok: stays up until it has been up SLEEP_MIN_AWAKE_S"

sleepy
sed -i.bak 's/^SLEEP_MIN_AWAKE_S=.*/SLEEP_MIN_AWAKE_S=10m/' "$work/box/checkout/config/launch.conf"
UPTIME=5 poll 0
up "SLEEP_MIN_AWAKE_S is not a number"
echo "ok: stays up when SLEEP_MIN_AWAKE_S is not a number"

sleepy
status hold
poll 0
up "the box is held" held
echo "ok: a held box stays up"

sleepy
echo '{"at": "2026-10-01T12:00:00Z"}' >"$D/hold-late"
poll 0
! grep -q "the box is held; nothing starts" "$work/out" || fail "the hold was there before the pass chose"
up "the box is held" held
echo "ok: a hold set after the pass chose what to start still keeps the box up"

# The heartbeat that went up says asleep; the next pass replaces it.
sleepy
echo '{"at": "2026-10-01T12:00:00Z"}' >"$D/hold-at-upload"
poll 0
! powered_off || fail "powered off under a hold"
grep -q "^poll: staying up: the box is held" "$work/out" || fail "no 'staying up: the box is held'"
rm "$D/hold-at-upload"
poll 0
up "the box is held" held
sleepy
touch "$D/run-at-upload"
poll 0
! powered_off || fail "powered off under a run"
grep -q "^poll: staying up: a run is going" "$work/out" || fail "no 'staying up: a run is going'"
echo "ok: a hold or a run that arrives while the asleep heartbeat goes up keeps the box up"

echo "poll: all tests passed"
