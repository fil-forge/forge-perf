#!/usr/bin/env bash
# Behavior of update.sh against a scratch checkout of a scratch origin, with
# systemctl and id stubbed on PATH and /etc written under a scratch root
# (FORGE_PERF_HOST_ROOT). Checks that the first-boot pass installs and enables
# only what the checkout has, that a pass with nothing new changes nothing,
# that provision.sh reruns only when host/ changed, that units follow the
# checkout in and out while units from elsewhere stay, that a failed provision
# is retried by the next pass, and the refusals: hand edits, a campaign box, a
# run in progress.
# SC2015: `check && echo ok || fail` is the intended shape; fail runs when
# either the check or the echo fails, and echo does not fail.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd -P)/update.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/update-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/root"
export LOG="$work/calls" WORK="$work"
touch "$work/enabled"

printf '#!/usr/bin/env bash\necho 0\n' >"$work/bin/id"
# systemctl keeps enabled units in $WORK/enabled; forge-perf-run is a oneshot
# unit, activating (and so not is-active) while $WORK/run-active exists.
cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$LOG"
case "$1 $2" in
  "is-active --quiet") exit 3 ;;
  "show -p") if [ -f "$WORK/run-active" ]; then echo activating; else echo inactive; fi ;;
  "is-enabled --quiet") grep -qxF "$3" "$WORK/enabled" ;;
  "enable --now") echo "$3" >>"$WORK/enabled" ;;
  "enable "*) echo "$2" >>"$WORK/enabled" ;;
  "disable --now") grep -vxF "$3" "$WORK/enabled" >"$WORK/e" || true; mv "$WORK/e" "$WORK/enabled" ;;
esac
STUB
chmod +x "$work/bin/id" "$work/bin/systemctl"

# The origin: two units, the persistent list naming one unit it lacks, host
# pins, and a provision.sh that records that it ran and fails while
# $WORK/provision-fails exists.
git init -q -b main "$work/seed"
g() { git -C "$work/seed" "$@"; }
g config user.name test
g config user.email test@example.invalid
g config commit.gpgsign false
mkdir -p "$work/seed/systemd" "$work/seed/host" "$work/seed/scripts/host" "$work/seed/docs"
echo "[Unit]" >"$work/seed/systemd/forge-perf-nvme.service"
echo "[Timer]" >"$work/seed/systemd/forge-perf-poll.timer"
printf '# comment\nforge-perf-nvme.service\nforge-perf-recover.service\n\nforge-perf-poll.timer\n' \
  >"$work/seed/systemd/enabled.persistent"
printf 'forge-perf-nvme.service\n' >"$work/seed/systemd/enabled.campaign"
echo "PIN=1" >"$work/seed/host/versions.env"
printf '#!/usr/bin/env bash\necho provision.sh >>"$LOG"\n[ ! -f "$WORK/provision-fails" ]\n' \
  >"$work/seed/scripts/host/provision.sh"
chmod +x "$work/seed/scripts/host/provision.sh"
g add -A
g commit -q -m seed
git clone -q --bare "$work/seed" "$work/origin.git"
g remote add origin "$work/origin.git"
git clone -q "$work/origin.git" "$work/checkout"
checkout="$work/checkout"

# push <message> <command...>: change the seed with the command and push it.
push() {
  local message="$1"
  shift
  (cd "$work/seed" && "$@")
  g add -A
  g commit -q -m "$message"
  g push -q origin main
}

conf() {
  printf 'FORGE_PERF_BOX_ID=main\nFORGE_PERF_MODE=%s\nFORGE_PERF_CHECKOUT=%s\nFORGE_PERF_REF=main\n' \
    "$1" "$checkout" >"$work/box.conf"
}
conf persistent

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
  env -u INVOCATION_ID -u FORGE_PERF_UPDATE_COPY PATH="$work/bin:$PATH" FORGE_PERF_BOX_CONF="$work/box.conf" \
    FORGE_PERF_HOST_ROOT="$work/root" FORGE_PERF_COPY_DIR="$work" FORGE_PERF_RUNTIME="$work/run" \
    FORGE_PERF_LOCK_HELD="${LOCK_HELD-1}" bash "$script" "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" -eq "$want" ] || { fail "$what: exit $got, want $want"; return 1; }
}
units="$work/root/etc/systemd/system"
called() { grep -qxF "$1" "$LOG"; }

if run 0 "first boot" --local; then
  [ -f "$units/forge-perf-nvme.service" ] && [ -f "$units/forge-perf-poll.timer" ] &&
    echo "ok: first boot installs the checkout's units" || fail "first boot: units not installed"
  called "systemctl enable forge-perf-nvme.service" && called "systemctl enable --now forge-perf-poll.timer" &&
    echo "ok: services enabled for the next boot, timers started" || fail "first boot: enable calls"
  grep -q "forge-perf-recover.service is not in this checkout yet" "$work/out" && ! grep -q recover "$LOG" &&
    echo "ok: a listed unit the checkout lacks is skipped" || fail "first boot: missing unit not skipped"
  called "systemctl daemon-reload" && called provision.sh &&
    [ "$(cat "$work/root/var/lib/forge-perf/state/provisioned-rev")" = "$(git -C "$checkout" rev-parse HEAD)" ] &&
    echo "ok: first boot reloads systemd, provisions and records the commit" || fail "first boot: reload or provision"
fi

if run 0 "a pass with nothing new"; then
  grep -q "already at" "$work/out" && ! grep -qE "systemctl enable|daemon-reload|provision" "$LOG" &&
    echo "ok: nothing new changes nothing" || fail "nothing new: changed something"
fi

push "docs" sh -c 'echo x >docs/notes.md'
if run 0 "a docs change"; then
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$(g rev-parse HEAD)" ] && ! called provision.sh &&
    echo "ok: a docs change moves the checkout and skips provisioning" || fail "docs: checkout or provision"
fi

push "pins" sh -c 'echo PIN=2 >host/versions.env'
run 0 "a host change" && called provision.sh &&
  echo "ok: a host/ change reruns provision.sh" || fail "host change: provision.sh did not run"

push "pins again" sh -c 'echo PIN=3 >host/versions.env'
touch "$work/provision-fails"
run 1 "a failed provision" && called provision.sh &&
  echo "ok: a failed provision fails the pass" || fail "failed provision: pass succeeded"
rm "$work/provision-fails"
run 0 "the pass after a failed provision" && called provision.sh &&
  echo "ok: the next pass retries provisioning" || fail "retry: provision.sh did not run"
run 0 "the pass after the retry" && ! called provision.sh &&
  echo "ok: a successful provision is not repeated" || fail "after retry: provision.sh ran again"

push "recover" sh -c 'echo "[Unit]" >systemd/forge-perf-recover.service'
if run 0 "a new unit"; then
  [ -f "$units/forge-perf-recover.service" ] && called "systemctl enable forge-perf-recover.service" &&
    echo "ok: a unit that lands is installed and enabled" || fail "new unit: not installed or enabled"
fi

echo "[Timer]" >"$units/forge-perf-expire.timer"
push "drop poll" git rm -q systemd/forge-perf-poll.timer
if run 0 "a removed unit"; then
  [ ! -f "$units/forge-perf-poll.timer" ] && called "systemctl disable --now forge-perf-poll.timer" &&
    echo "ok: a unit the checkout dropped is stopped and removed" || fail "removed unit: still there"
  [ -f "$units/forge-perf-expire.timer" ] &&
    echo "ok: a unit installed by something else stays" || fail "removed unit: foreign unit deleted"
fi

push "later" sh -c 'echo y >docs/notes.md'
echo "# hand edit" >>"$checkout/host/versions.env"
before="$(git -C "$checkout" rev-parse HEAD)"
run 1 "hand edits" && [ "$(git -C "$checkout" rev-parse HEAD)" = "$before" ] &&
  grep -q "hand edits" "$work/out" &&
  echo "ok: hand edits to tracked files stop the update" || fail "hand edits: not refused"
git -C "$checkout" checkout -q -- host/versions.env

touch "$work/run-active"
run 1 "a run in progress" && grep -q "forge-perf-run.service is activating" "$work/out" &&
  echo "ok: a running oneshot run unit stops the update" || fail "active run: not refused"
rm "$work/run-active"

if command -v flock >/dev/null; then
  mkdir -p "$work/run"
  exec 8>"$work/run/run.lock"
  flock 8
  LOCK_HELD="" run 1 "the run lock held" && grep -q "run.lock" "$work/out" &&
    echo "ok: a held run lock stops the update" || fail "run lock: not refused"
  exec 8>&-
fi

conf campaign
run 1 "a campaign box" && grep -q "campaign box stays" "$work/out" &&
  echo "ok: a campaign box never fetches" || fail "campaign: not refused"
run 0 "a campaign first boot" --local &&
  echo "ok: --local works on a campaign box" || fail "campaign --local failed"

[ "$failures" -eq 0 ] || exit 1
echo "update_test: all passed"
