#!/usr/bin/env bash
# Behavior of ssm-session.sh, box-update.sh and latest-ami.sh with aws stubbed
# on PATH: which instance each reaches, what box-update.sh sends and how it
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
# prints $WORK/instances; get-command-invocation walks $WORK/statuses one line
# per call, then repeats the last.
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" "" >>"$LOG"
case "$1 $2" in
  "ec2 describe-instances") cat "$WORK/instances" ;;
  "ec2 describe-images") echo "ami-0abc1234567890def	ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-20261001	2026-10-01T00:00:00.000Z" ;;
  "ssm start-session") echo "session started" ;;
  "ssm send-command") echo cmd-0test ;;
  "ssm get-command-invocation")
    case "$*" in
      *"--query Status"*)
        head -1 "$WORK/statuses"
        [ "$(wc -l <"$WORK/statuses")" -le 1 ] || sed -i.bak 1d "$WORK/statuses" ;;
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
  env PATH="$work/bin:$PATH" BOX_UPDATE_POLL_SECONDS=0 "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" -eq "$want" ] || { fail "$what: exit $got, want $want"; return 1; }
}
asked() { grep -qxF -- "$1" "$LOG"; }

echo i-0main >"$work/instances"
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

if run 0 "latest-ami" bash "$dir/latest-ami.sh"; then
  asked "099720109477" && asked "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" &&
    grep -q "^ami-0abc1234567890def " "$work/out" && grep -q "set ami_id to ami-0abc1234567890def" "$work/out" &&
    echo "ok: latest-ami.sh prints Canonical's newest noble arm64 gp3 image and the pinned one" || fail "latest-ami"
fi
run 1 "latest-ami for another architecture" bash "$dir/latest-ami.sh" i386 &&
  echo "ok: latest-ami.sh takes arm64 or amd64 only" || fail "latest-ami arch"

[ "$failures" -eq 0 ] || exit 1
echo "box_scripts_test: all passed"
