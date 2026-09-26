#!/usr/bin/env bash
# Behavior of campaign.sh against stubs: systemctl records the pending run
# each `start --wait forge-perf-run.service` would take and takes it, as
# run.sh does; systemd-run records the poweroff timer; id answers 0, so the
# scripts run as on the box without FORGE_PERF_HOST_OPS=skip.
set -euo pipefail

host="$(cd "$(dirname "$0")/.." && pwd -P)"
repo="$(cd "$host/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/campaign-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export D="$work/d"
mkdir -p "$work/bin"
unset INVOCATION_ID FORGE_PERF_LOCK_HELD FORGE_PERF_HOST_OPS

cat >"$work/bin/id" <<'STUB'
#!/usr/bin/env bash
echo 0
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$D/systemctl.log"
case "$*" in
  "start --wait forge-perf-run.service")
    jq -c . "$FORGE_PERF_STATE_DIR/pending.json" >>"$D/runs.log"
    rm "$FORGE_PERF_STATE_DIR/pending.json"
    jq -n '{run_id: "campaign-1", kind: "campaign"}' >"$FORGE_PERF_STATE_DIR/last-run.json" ;;
  "is-active --quiet forge-perf-expire.timer") exit 1 ;;
esac
STUB
cat >"$work/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "systemd-run $*" >>"$D/systemctl.log"
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

fail() {
  echo "FAIL: $*" >&2
  sed 's/^/  | /' "$work/out" >&2 || true
  exit 1
}
state="$work/box/state"
git() { /usr/bin/git -C "$work/checkout" -c user.name=t -c user.email=t@t "$@"; }

# setup MODE: a checkout of this tree's config, sets and host scripts, in
# one commit, which campaign.json names.
setup() {
  rm -rf "$work/box" "$work/checkout" "$D"
  mkdir -p "$D" "$state" "$work/box/outbox" "$work/box/run" "$work/checkout/calibration/sets" \
    "$work/checkout/scripts"
  cp -R "$repo/config" "$work/checkout/"
  cp -R "$repo/scripts/host" "$work/checkout/scripts/"
  cp "$repo/calibration/sets/shakedown.json" "$work/checkout/calibration/sets/"
  git init -q && git add -A && git commit -qm one
  sha="$(git rev-parse HEAD)"
  printf '%s\n' FORGE_PERF_BOX_ID=campaign "FORGE_PERF_MODE=$1" "FORGE_PERF_CHECKOUT=$work/checkout" \
    FORGE_PERF_RESULTS_BUCKET=test-results >"$work/box/box.conf"
}
# conf JQ: campaign.json, a campaign of two runs at 16 workers pinned at
# $sha and expiring in an hour, edited by JQ.
conf() {
  jq -n --arg sha "$sha" --argjson at "$(($(date -u +%s) + 3600))" \
    '{mode: "campaign", set: "calibration/sets/shakedown.json", runs: 2, size: "10GB", workers: [16],
      duration: "30m", forge_perf_sha: $sha, expires_at: ($at | todate)}' | jq "$1" >"$work/box/campaign.json"
}
campaign() {
  local want="$1" got=0
  shift
  env FORGE_PERF_BOX_CONF="$work/box/box.conf" FORGE_PERF_CAMPAIGN_CONF="$work/box/campaign.json" \
    FORGE_PERF_STATE_DIR="$state" FORGE_PERF_OUTBOX="$work/box/outbox" FORGE_PERF_RUNTIME="$work/box/run" \
    FORGE_PERF_FLUSH_RETRY_S=0 bash "$work/checkout/scripts/host/campaign.sh" "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "campaign.sh $* exited $got, wanted $want"
}
runs() { jq -r "$1" "$D/runs.log" 2>/dev/null | paste -sd' ' -; }
setup campaign
first="$sha"
git commit -q --allow-empty -m two
sha="$(git rev-parse HEAD)"
git checkout -q --detach "$first"
conf .
campaign 0
[ "$(git rev-parse HEAD)" = "$sha" ] || fail "not at forge_perf_sha"
[ "$(runs '"\(.kind)/\(.series)/\(.workers)/\(.size)/\(.duration)/\(.pairing_id)"')" = \
  "campaign/campaign/16/10GB/30m/null campaign/campaign/16/10GB/30m/null" ] || fail "runs $(cat "$D/runs.log")"
[ "$(runs '.set.smelt')" = "$(jq -r .smelt "$repo/calibration/sets/shakedown.json") $(jq -r .smelt "$repo/calibration/sets/shakedown.json")" ] ||
  fail "set"
grep -q "systemd-run --unit forge-perf-expire --on-calendar [0-9-]* [0-9:]* UTC .*/usr/bin/systemctl poweroff" \
  "$D/systemctl.log" || fail "no poweroff timer"
[ "$(tail -1 "$D/systemctl.log")" = "systemctl poweroff" ] || fail "no poweroff at the end"
[ ! -e "$state/pending.json" ] && [ ! -e "$state/last-run.json" ] || fail "a campaign's state left behind"
echo "ok: a campaign box checks out its commit, runs the set twice, and powers off"

rm "$D/runs.log"
campaign 0
[ ! -e "$D/runs.log" ] || fail "a finished campaign ran again"
jq '.done = 1' "$state/campaign-progress.json" >"$work/p" && mv "$work/p" "$state/campaign-progress.json"
campaign 0
[ "$(runs .workers)" = 16 ] || fail "resume ran $(runs .workers)"
echo "ok: after a reboot the campaign resumes after its last run"

setup campaign
conf '.workers = [16, 32, 64]'
campaign 0
[ "$(runs '"\(.workers)"')" = "16 32 64 64 32 16" ] || fail "sweep order $(runs .workers)"
[ "$(runs .series | tr ' ' '\n' | sort -u)" = calibration ] || fail "a sweep is not calibration"
echo "ok: a workers list sweeps 16 32 64 64 32 16 as series calibration"

setup campaign
conf '.runs = 99'
campaign 1
[ ! -e "$D/runs.log" ] && [ "$(tail -1 "$D/systemctl.log")" = "systemctl poweroff" ] || fail "an error left the box up"
grep -q "stopped on an error" "$work/out" || fail "no word of the error"
echo "ok: a campaign box that stops on an error powers off"

setup campaign
conf '.mode = "calibration"'
campaign 0
[ ! -e "$D/runs.log" ] || fail "mode calibration ran the set"
grep -q "systemd-run --unit forge-perf-expire" "$D/systemctl.log" || fail "no poweroff timer"
grep -qx "systemctl poweroff" "$D/systemctl.log" && fail "mode calibration powered off"
conf '.expires_at = "2020-01-01T00:00:00Z"'
campaign 0
[ ! -e "$D/runs.log" ] && [ "$(tail -1 "$D/systemctl.log")" = "systemctl poweroff" ] || fail "past expiry"
echo "ok: mode calibration runs nothing, and a box past expires_at powers off at once"

setup persistent
cp "$repo/calibration/sets/shakedown.json" "$work/set.json"
campaign 1 --set "$work/set.json" --runs 3 --pairing pair-20261001-t1
grep -q "hold the box first" "$work/out" || fail "an unheld box ran a campaign"
campaign 1
grep -q "only a campaign box" "$work/out" || fail "campaign.json on a persistent box"
echo '{"at": "2026-10-01T12:00:00Z"}' >"$state/hold"
campaign 1 --set "$work/set.json" --runs 3 --pairing pair-1
grep -q "pair-<yyyymmdd>-<id>" "$work/out" || fail "a malformed pairing ID"
campaign 0 --set "$work/set.json" --runs 3 --pairing pair-20261001-t1
[ "$(runs '"\(.kind)/\(.series)/\(.pairing_id)/\(.workers)/\(.size)"')" = \
  "$(printf 'campaign/campaign/pair-20261001-t1/null/null %.0s' 1 2 3 | sed 's/ $//')" ] || fail "paired $(cat "$D/runs.log")"
grep -q poweroff "$D/systemctl.log" && fail "a persistent box powered off"
[ -e "$state/hold" ] || fail "the hold went"
echo "ok: on a held persistent box, --set runs N paired runs on the settings file's values"

echo "campaign: all tests passed"
