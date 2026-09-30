#!/usr/bin/env bash
# Behavior of ssm-session.sh, box-update.sh, hold.sh, wake.sh and latest-ami.sh
# with aws stubbed on PATH: which instance each reaches, how a sleeping box is
# woken first, what box-update.sh and hold.sh send and how box-update.sh
# reports the result, and what latest-ami.sh asks EC2 for.
# SC2015: `check && echo ok || fail` is the intended shape; fail runs when
# either the check or the echo fails, and echo does not fail.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/box-scripts-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export LOG="$work/calls" WORK="$work"

# Arguments one per line, a blank line between calls. describe-instances
# prints the IDs in $WORK/instances. A file of answers ($WORK/states,
# $WORK/pings, $WORK/statuses) is walked one line per call, then repeats the
# last: states by each lookup that asks for the state, pings by
# describe-instance-information and statuses by get-command-invocation. Every
# instance is in the state the last such lookup gave, and carries the
# ExpiresAt tag in $WORK/expires, None when the file is missing.
# describe-instance-information fails with the message in $WORK/ping-fails
# when that file exists.
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" "" >>"$LOG"
walk() {
  head -1 "$1"
  [ "$(wc -l <"$1")" -le 1 ] || sed -i.bak 1d "$1"
}
case "$1 $2" in
  "ec2 describe-instances")
    case " $* " in
      *" Name=instance-state-name,Values=running "*)
        [ "$(cat "$WORK/state-now" 2>/dev/null || head -1 "$WORK/states")" != running ] || cat "$WORK/instances" ;;
      *)
        state="$(walk "$WORK/states")"
        echo "$state" >"$WORK/state-now"
        expires="$(cat "$WORK/expires" 2>/dev/null || echo None)"
        for id in $(cat "$WORK/instances"); do printf '%s\t%s\t%s\n' "$id" "$state" "$expires"; done ;;
    esac ;;
  "ec2 start-instances") [ ! -e "$WORK/start-fails" ] || exit 254 ;;
  "ec2 describe-images") echo "ami-0abc1234567890def	ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-20261001	2026-10-01T00:00:00.000Z" ;;
  "ssm describe-instance-information")
    if [ -e "$WORK/ping-fails" ]; then
      printf '\n%s\n' "$(cat "$WORK/ping-fails")" >&2
      exit 254
    fi
    walk "$WORK/pings" ;;
  "ssm start-session") echo "session started" ;;
  "ssm send-command") echo cmd-0test ;;
  "ssm get-command-invocation")
    case "$*" in
      *"--query Status"*) walk "$WORK/statuses" ;;
      *) echo "=== updated ===" ;;
    esac ;;
esac
STUB
chmod +x "$work/bin/aws"

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
  env PATH="$work/bin:$PATH" BOX_UPDATE_POLL_SECONDS=0 HOLD_POLL_SECONDS=0 BOX_WAKE_POLL_SECONDS=0 \
    "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" -eq "$want" ] || { fail "$what: exit $got, want $want"; return 1; }
}
asked() { grep -qxF -- "$1" "$LOG"; }
calls() { grep -cxF -- "$1" "$LOG" || true; }
# A box in each state in turn, one per lookup, and the agent's ping status
# once it is running, one per check.
box() {
  printf '%s\n' "$@" >"$work/states"
  rm -f "$work/state-now"
  echo Online >"$work/pings"
}

echo i-0main >"$work/instances"
box running
if run 0 "ssm-session main" bash "$dir/ssm-session.sh" main; then
  asked "Name=tag:Box,Values=main" && asked "Name=instance-state-name,Values=running" &&
    asked "start-session" && asked "i-0main" &&
    echo "ok: ssm-session.sh opens a session on the running box tagged Box=main" || fail "ssm-session: calls"
fi
run 1 "a malformed box name" bash "$dir/ssm-session.sh" 'main;x' && ! grep -q describe "$LOG" &&
  echo "ok: a malformed box name is refused before any call" || fail "malformed name"
: >"$work/instances"
run 1 "no box" bash "$dir/ssm-session.sh" campaign && grep -q "no running box 'campaign'" "$work/out" &&
  echo "ok: no running box is an error" || fail "no box"
printf 'i-0a\ti-0b\n' >"$work/instances"
run 1 "two boxes" bash "$dir/ssm-session.sh" main && grep -q "more than one" "$work/out" &&
  echo "ok: two running boxes of one name is an error" || fail "two boxes"

echo i-0main >"$work/instances"
printf 'Pending\nInProgress\nSuccess\n' >"$work/statuses"
if run 0 "box-update main" bash "$dir/box-update.sh" main; then
  asked "AWS-RunShellScript" && asked 'commands=["/opt/forge-perf/scripts/host/update.sh"],executionTimeout=["1800"]' &&
    asked "i-0main" && grep -q "=== updated ===" "$work/out" &&
    [ "$(grep -c '^get-command-invocation$' "$LOG")" -eq 4 ] &&
    [ "$(calls describe-instances)" -eq 2 ] &&
    echo "ok: box-update.sh runs update.sh on main, waits for it and prints its output" || fail "box-update: calls"
fi
printf 'InProgress\nFailed\n' >"$work/statuses"
run 1 "a failed update" bash "$dir/box-update.sh" main && grep -q "update.sh ended Failed" "$work/out" &&
  grep -q "=== updated ===" "$work/out" &&
  echo "ok: a failed update prints its output and exits non-zero" || fail "failed update"
printf 'InProgress\n' >"$work/statuses"
run 1 "an update that does not finish" env BOX_UPDATE_WAIT_SECONDS=0 bash "$dir/box-update.sh" main &&
  grep -q "still InProgress" "$work/out" &&
  echo "ok: box-update.sh gives up after its wait" || fail "timeout"

# A sleeping box: stopped, started, pending, then running with the agent
# online one check later.
echo i-0main >"$work/instances"
box stopped pending running
printf 'None\nConnectionLost\nOnline\n' >"$work/pings"
if run 0 "wake a stopped box" bash "$dir/wake.sh" main; then
  asked "Name=instance-state-name,Values=pending,running,stopping,stopped" &&
    [ "$(calls start-instances)" -eq 1 ] && asked "i-0main" &&
    [ "$(calls describe-instance-information)" -eq 3 ] && asked "Key=InstanceIds,Values=i-0main" &&
    [ "$(tail -1 "$work/out")" = i-0main ] &&
    echo "ok: wake.sh starts a stopped box, waits for it to be online and prints its ID" || fail "wake: stopped"
fi
box stopped pending running
[ "$(PATH="$work/bin:$PATH" BOX_WAKE_POLL_SECONDS=0 bash "$dir/wake.sh" main 2>/dev/null)" = i-0main ] &&
  echo "ok: wake.sh prints the ID alone on stdout" || fail "wake: stdout"
box running
run 0 "wake a running box" bash "$dir/wake.sh" main && [ "$(calls start-instances)" -eq 0 ] &&
  [ "$(cat "$work/out")" = i-0main ] &&
  echo "ok: a box that is up is not started and nothing but its ID is printed" || fail "wake: running"
box stopping stopping stopped pending running
if run 0 "wake a stopping box" bash "$dir/wake.sh" main; then
  [ "$(calls start-instances)" -eq 1 ] &&
    [ "$(sed '/^start-instances$/q' "$LOG" | grep -c '^describe-instances$')" -eq 3 ] &&
    [ "$(tail -1 "$work/out")" = i-0main ] &&
    echo "ok: a stopping box is started once it has stopped" || fail "wake: stopping"
fi
box pending running
run 0 "wake a pending box" bash "$dir/wake.sh" main && [ "$(calls start-instances)" -eq 0 ] &&
  [ "$(tail -1 "$work/out")" = i-0main ] &&
  echo "ok: a box already starting is waited for, not started again" || fail "wake: pending"
box running
echo ConnectionLost >"$work/pings"
run 1 "a box that never comes online" env BOX_WAKE_WAIT_SECONDS=0 bash "$dir/box-update.sh" main &&
  grep -q "box 'main' (i-0main) is running but not online in Session Manager after 0s" "$work/out" &&
  [ "$(calls send-command)" -eq 0 ] &&
  echo "ok: a box that never reaches SSM Online is an error and nothing is sent" || fail "never online"
box stopped stopped stopped pending running
run 0 "a box EC2 still calls stopped after the start" bash "$dir/wake.sh" main &&
  [ "$(calls start-instances)" -eq 1 ] && [ "$(tail -1 "$work/out")" = i-0main ] &&
  echo "ok: a box still reported stopped after the start is not started twice" || fail "wake: started twice"
grep -q 'wait="${BOX_WAKE_WAIT_SECONDS:-600}"' "$dir/lib.sh" &&
  echo "ok: the wait for a box to come up is 10 minutes unless overridden" || fail "wake: default wait"
box running
echo "An error occurred (AccessDeniedException) when calling the DescribeInstanceInformation operation" >"$work/ping-fails"
run 1 "a ping check that fails" env BOX_WAKE_WAIT_SECONDS=0 bash "$dir/wake.sh" main &&
  grep -q "^ERROR: box 'main' (i-0main) is running, and its Session Manager status could not be read: An error occurred (AccessDeniedException).* after 0s" "$work/out" &&
  echo "ok: a Session Manager check that fails is reported with AWS's error" || fail "ping fails"
rm "$work/ping-fails"

box stopped
run 1 "a box that never starts" env BOX_WAKE_WAIT_SECONDS=0 bash "$dir/wake.sh" main &&
  grep -q "box 'main' (i-0main) is stopped after 0s" "$work/out" && ! grep -qx i-0main "$work/out" &&
  echo "ok: a box that stays stopped is an error and no ID is printed" || fail "never starts"
box stopped pending running
touch "$work/start-fails"
run 1 "a start that is refused" bash "$dir/wake.sh" main && grep -q "could not start box 'main' (i-0main)" "$work/out" &&
  [ "$(calls describe-instances)" -eq 1 ] &&
  echo "ok: a refused start is an error at once" || fail "refused start"
rm "$work/start-fails"
: >"$work/instances"
box stopped
run 1 "wake no box" bash "$dir/wake.sh" main && grep -q "no running box 'main'" "$work/out" &&
  [ "$(calls start-instances)" -eq 0 ] &&
  echo "ok: waking a box that does not exist is an error" || fail "wake: no box"
printf 'i-0a\ti-0b\n' >"$work/instances"
run 1 "wake two boxes" bash "$dir/wake.sh" main && grep -q "more than one box 'main': i-0a i-0b" "$work/out" &&
  [ "$(calls start-instances)" -eq 0 ] &&
  echo "ok: two boxes of one name are an error and neither is started" || fail "wake: two boxes"
run 1 "wake a malformed box name" bash "$dir/wake.sh" 'main;x' && ! grep -q describe "$LOG" &&
  echo "ok: wake.sh refuses a malformed box name before any call" || fail "wake: malformed name"
run 1 "wake with no box name" bash "$dir/wake.sh" && grep -q "usage: wake.sh <box>" "$work/out" &&
  echo "ok: wake.sh wants a box name" || fail "wake: usage"

# A box with ExpiresAt (campaign, scratch) powers off for good: its campaign
# unit would resume the runs at boot. It is reached while it is up and never
# started.
echo i-0main >"$work/instances"
echo 2026-10-01T00:00:00Z >"$work/expires"
for script in wake.sh ssm-session.sh box-update.sh "hold.sh on"; do
  box stopped pending running
  # shellcheck disable=SC2086  # "hold.sh on" is a script and its argument
  set -- $script
  run 1 "$1 on a stopped campaign box" bash "$dir/$1" campaign ${2:+"$2"} &&
    grep -q "^ERROR: box 'campaign' (i-0main) is stopped; it powered off when its runs ended or at its ExpiresAt, and only a box that sleeps is woken" "$work/out" &&
    [ "$(calls start-instances)" -eq 0 ] && [ "$(calls start-session)" -eq 0 ] && [ "$(calls send-command)" -eq 0 ] &&
    echo "ok: $1 does not start a stopped box that carries ExpiresAt" || fail "$1: stopped campaign box"
done
box stopping stopped
run 1 "wake a campaign box that is powering off" env BOX_WAKE_WAIT_SECONDS=2 bash "$dir/wake.sh" campaign &&
  grep -q "is stopped; it powered off" "$work/out" && [ "$(calls start-instances)" -eq 0 ] &&
  echo "ok: a box with ExpiresAt that is stopping is not started once it has stopped" || fail "wake: stopping campaign box"
box running
run 0 "ssm-session on a running campaign box" bash "$dir/ssm-session.sh" campaign &&
  [ "$(calls start-instances)" -eq 0 ] && asked "start-session" &&
  echo "ok: a running box with ExpiresAt is reached as before" || fail "ssm-session: running campaign box"
rm "$work/expires"

# The scripts that reach a box wake it first.
echo i-0main >"$work/instances"
box stopped pending running
if run 0 "ssm-session on a sleeping box" bash "$dir/ssm-session.sh" main; then
  [ "$(calls start-instances)" -eq 1 ] && asked "start-session" && grep -q "session started" "$work/out" &&
    [ "$(sed '/^start-session$/q' "$LOG" | grep -c '^start-instances$')" -eq 1 ] &&
    echo "ok: ssm-session.sh wakes a sleeping box, then opens the session" || fail "ssm-session: sleeping"
fi
box stopped pending running
echo Success >"$work/statuses"
if run 0 "box-update on a sleeping box" bash "$dir/box-update.sh" main; then
  [ "$(calls start-instances)" -eq 1 ] &&
    asked 'commands=["/opt/forge-perf/scripts/host/update.sh"],executionTimeout=["1800"]' &&
    grep -q "=== updated ===" "$work/out" &&
    echo "ok: box-update.sh wakes a sleeping box, then runs update.sh" || fail "box-update: sleeping"
fi
box stopped pending running
printf 'InProgress\nSuccess\n' >"$work/statuses"
if run 0 "hold on a sleeping box" bash "$dir/hold.sh" main on; then
  [ "$(calls start-instances)" -eq 1 ] &&
    asked 'commands=["/opt/forge-perf/scripts/host/status.sh hold --wait-idle"],executionTimeout=["25200"]' &&
    asked "i-0main" && [ "$(calls get-command-invocation)" -eq 3 ] &&
    echo "ok: hold.sh on wakes a sleeping box, sets the hold and waits for it" || fail "hold on: sleeping"
fi
# A box that went to sleep just after it was found: Run Command accepts the
# command and it stays Pending until the box is up again.
box running stopped pending running
printf 'Pending\nPending\nSuccess\n' >"$work/statuses"
if run 0 "box-update on a box that slept under the command" env BOX_PENDING_REWAKE_SECONDS=0 bash "$dir/box-update.sh" main; then
  [ "$(calls start-instances)" -eq 1 ] && [ "$(calls send-command)" -eq 1 ] &&
    [ "$(sed '/^start-instances$/q' "$LOG" | grep -c '^send-command$')" -eq 1 ] &&
    grep -q "=== updated ===" "$work/out" &&
    echo "ok: box-update.sh wakes a box again when its command stays Pending" || fail "box-update: pending"
fi
box running stopped pending running
printf 'Pending\nPending\nSuccess\n' >"$work/statuses"
if run 0 "hold on a box that slept under the command" env BOX_PENDING_REWAKE_SECONDS=0 bash "$dir/hold.sh" main on; then
  [ "$(calls start-instances)" -eq 1 ] && [ "$(calls send-command)" -eq 1 ] &&
    [ "$(sed '/^start-instances$/q' "$LOG" | grep -c '^send-command$')" -eq 1 ] &&
    echo "ok: hold.sh wakes a box again when its command stays Pending" || fail "hold: pending"
fi
box stopped pending running
echo Success >"$work/statuses"
if run 0 "hold off on a sleeping box" bash "$dir/hold.sh" main off; then
  [ "$(calls start-instances)" -eq 1 ] &&
    asked 'commands=["/opt/forge-perf/scripts/host/status.sh release"],executionTimeout=["25200"]' &&
    echo "ok: hold.sh off wakes a sleeping box too, then releases the hold" || fail "hold off: sleeping"
fi
box running
echo Success >"$work/statuses"
if run 0 "hold off" bash "$dir/hold.sh" main off; then
  [ "$(calls start-instances)" -eq 0 ] &&
    asked 'commands=["/opt/forge-perf/scripts/host/status.sh release"],executionTimeout=["25200"]' &&
    echo "ok: hold.sh off releases the hold on a box that is up without starting it" || fail "hold off"
fi
echo Failed >"$work/statuses"
run 1 "a failed hold" bash "$dir/hold.sh" main on && grep -q "status.sh ended Failed" "$work/out" &&
  echo "ok: a failed hold exits non-zero" || fail "failed hold"
run 1 "hold with no on or off" bash "$dir/hold.sh" main && grep -q "usage: hold.sh <box> on|off" "$work/out" &&
  ! grep -q describe "$LOG" &&
  echo "ok: hold.sh wants on or off before any call" || fail "hold: usage"

if run 0 "latest-ami" bash "$dir/latest-ami.sh"; then
  asked "099720109477" && asked "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" &&
    grep -q "^ami-0abc1234567890def " "$work/out" && grep -q "set ami_id to ami-0abc1234567890def" "$work/out" &&
    echo "ok: latest-ami.sh prints Canonical's newest noble arm64 gp3 image and the pinned one" || fail "latest-ami"
fi
run 1 "latest-ami for another architecture" bash "$dir/latest-ami.sh" i386 &&
  echo "ok: latest-ami.sh takes arm64 or amd64 only" || fail "latest-ami arch"

[ "$failures" -eq 0 ] || exit 1
echo "box_scripts_test: all passed"
