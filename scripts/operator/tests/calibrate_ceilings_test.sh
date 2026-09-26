#!/usr/bin/env bash
# Behavior of calibrate-ceilings.sh against stubbed aws and gh: the box's type
# and Session Manager state come from $WORK files, the SSM command reports
# InProgress once and then $WORK/status, and `s3 cp` writes a summary.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2016
set -euo pipefail

repo="$(cd "$(dirname "$0")/../../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/calibrate-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/tree/scripts"
cp -R "$repo/scripts/operator" "$work/tree/scripts/"
export WORK="$work" CALIBRATE_POLL_SECONDS=0

cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$WORK/aws.log"
case "$1 $2" in
  "ec2 describe-instances")
    case "$*" in *--instance-ids*) cat "$WORK/type" ;; *) echo i-0abc ;; esac ;;
  "ssm describe-instance-information") echo Online ;;
  "ssm send-command") echo cmd-1 ;;
  "ssm get-command-invocation")
    case "$*" in
      *"--query Status"*)
        if [ -e "$WORK/polled" ]; then cat "$WORK/status"; else touch "$WORK/polled"; echo InProgress; fi ;;
      *) printf 'ceiling.sh output\t\n' ;;
    esac ;;
  "s3 cp")
    echo '{"instance_type": "m9gd.2xlarge", "quick": false, "ceiling": 5, "limited_by": "s3_put",
      "s3_put": {"p5": 5}, "nvme_write": {"p5": 9}}' >"$6/summary.json" ;;
  *) exit 1 ;;
esac
STUB
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$WORK/gh.log"
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

fail() {
  echo "FAIL: $*" >&2
  sed 's/^/  | /' "$work/out" >&2 || true
  exit 1
}
calibrate() {
  local want="$1" got=0
  shift
  rm -f "$work/aws.log" "$work/gh.log" "$work/polled"
  bash "$work/tree/scripts/operator/calibrate-ceilings.sh" "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "calibrate-ceilings.sh $* exited $got, wanted $want"
}

echo m9gd.2xlarge >"$work/type"
echo Success >"$work/status"
calibrate 0 m9gd.2xlarge --date 2026-10-06
grep -q 'send-command .*--document-name AWS-RunShellScript .*commands=\["/opt/forge-perf/scripts/host/ceiling.sh --date 2026-10-06"\],executionTimeout=\["14400"\]' \
  "$work/aws.log" || fail "the SSM command"
grep -q "s3 cp --recursive --only-show-errors s3://forge-perf-results-654654381893/raw/calibration/2026-10-06/m9gd.2xlarge/ [^ ]*/tree/calibration/ceilings/2026-10-06/m9gd.2xlarge/$" \
  "$work/aws.log" || fail "the evidence copy"
[ -f "$work/tree/calibration/ceilings/2026-10-06/m9gd.2xlarge/summary.json" ] || fail "no summary in the tree"
grep -q '"ceiling":5,"limited_by":"s3_put"' "$work/out" || fail "the summary line"
grep -qx "gh workflow run campaign.yml -R fil-forge/forge-perf --ref main -f action=down -f instance_type=m9gd.2xlarge" \
  "$work/gh.log" || fail "the teardown"
echo "ok: measures over SSM, copies the evidence into calibration/ceilings and dispatches down"

calibrate 0 m9gd.2xlarge --date 2026-10-06 --quick --keep --workers 128
grep -q 'ceiling.sh --date 2026-10-06 --quick --workers 128"' "$work/aws.log" || fail "--quick and --workers reach the box"
[ -f "$work/tree/local/ceilings/2026-10-06/m9gd.2xlarge/summary.json" ] || fail "--quick lands in local/"
[ ! -e "$work/gh.log" ] || fail "--keep dispatched down"
echo "ok: --quick lands in local/ceilings and --keep leaves the box"

echo Failed >"$work/status"
calibrate 1 m9gd.2xlarge --date 2026-10-07
grep -q "ended Failed" "$work/out" || fail "failure message"
if [ -e "$work/gh.log" ] || grep -q "s3 cp" "$work/aws.log"; then fail "a failed measurement copied or tore down"; fi
echo Success >"$work/status"
calibrate 1 m9gd.8xlarge --date 2026-10-07
grep -q "the campaign box is m9gd.2xlarge, not m9gd.8xlarge" "$work/out" || fail "type mismatch message"
! grep -q send-command "$work/aws.log" || fail "measured the wrong type"
calibrate 1 m7i.large
calibrate 1 m9gd.2xlarge --workers "64;x"
calibrate 1 m9gd.2xlarge --date 06/10/2026
echo "ok: a failed command, the wrong type, an unknown type and a bad date are refused"
