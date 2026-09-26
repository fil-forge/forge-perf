#!/usr/bin/env bash
# Behavior of scratch-box.sh with aws stubbed on PATH: what `up` asks EC2 for,
# the refusals before any call, and what `down` terminates.
# SC2015: `check && echo ok || fail` is the intended shape; fail runs when
# either the check or the echo fails, and echo does not fail.
# SC2016: stub bodies expand in the stub, not here.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd -P)/scratch-box.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/scratch-box-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export LOG="$work/calls" WORK="$work"

# Arguments one per line, a blank line between calls. describe-subnets finds
# the forge-perf subnet $FP_SUBNET (none when unset) in $FP_VPC, which is the
# default VPC unless set, as the network root places it; then a default one;
# describe-security-groups finds sg-<vpc id> unless $NO_SG is set; the profile's
# role has the deny policy unless $NO_DENY is set; describe-instances lists
# $WORK/instances.
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" "" >>"$LOG"
case "$2 $*" in
  "describe-subnets "*tag:Name*) if [ -n "${FP_SUBNET:-}" ]; then printf '%s\t%s\n' "$FP_SUBNET" "${FP_VPC:-vpc-default}"; else echo None; fi ;;
  "describe-subnets "*) printf 'subnet-default2a\tvpc-default\n' ;;
  "describe-security-groups "*)
    if [ -n "${NO_SG:-}" ]; then echo None; else echo "sg-$(printf '%s\n' "$@" | grep -o 'vpc-[a-z]*$')"; fi ;;
  "get-instance-profile "*) echo forge-perf-scratch-role ;;
  "get-role-policy "*) [ -z "${NO_DENY:-}" ] || { echo "NoSuchEntity" >&2; exit 254; } ;;
  "describe-instances "*) cat "$WORK/instances" 2>/dev/null || true ;;
  "run-instances "*) echo i-0scratch ;;
esac
STUB
chmod +x "$work/bin/aws"

failures=0
sha=0123456789abcdef0123456789abcdef01234567
run() {
  local want="$1" what="$2" got=0
  shift 2
  : >"$LOG"
  env PATH="$work/bin:$PATH" SCRATCH_INSTANCE_PROFILE=forge-perf-scratch "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" -eq "$want" ] || { fail "$what: exit $got, want $want"; return 1; }
}
fail() {
  echo "FAIL: $*"
  sed 's/^/    /' "$work/out" "$LOG"
  failures=$((failures + 1))
}
has() { grep -qxF -- "$1" "$LOG"; }
# in_call <command> <arg> <next-arg>: the call to <command> passes <arg> then <next-arg>.
in_call() {
  awk -v c="$1" -v a="$2" -v b="$3" '
    $0 == "" { call = ""; prev = ""; next }
    call == "" && prev == "ec2" { call = $0 }
    call == c && prev == a && $0 == b { f = 1 }
    { prev = $0 }
    END { exit !f }' "$LOG"
}
# expires_at <tag value>: the poweroff timer fires at the tagged time, about
# two hours from now.
expires_at() {
  local cal now at
  cal="$(echo "$1" | tr T ' ' | tr -d Z)"
  grep -qxF "OnCalendar=$cal UTC" "$LOG" || return 1
  now="$(date -u +%s)"
  at="$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s)"
  [ $((at - now)) -gt 7000 ] && [ $((at - now)) -le 7200 ]
}

if run 0 "up" bash "$script" up --hours 2 --ref "$sha"; then
  has ami-03e774c3214166a53 && has subnet-default2a && has m9gd.2xlarge && has terminate &&
    has 'HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled' &&
    has 'Name=forge-perf-scratch' && has --associate-public-ip-address &&
    in_call run-instances --security-group-ids sg-vpc-default &&
    has Name=group-name,Values=forge-perf-scratch && has Name=vpc-id,Values=vpc-default &&
    has deny-parameter-reads && has forge-perf-scratch-role &&
    grep -qE '^ResourceType=instance,Tags=\[\{Key=Project,Value=forge-perf\},\{Key=Box,Value=scratch\},.*\{Key=ExpiresAt,Value=20[0-9-]+T[0-9:]+Z\}\]$' "$LOG" &&
    expires_at "$(grep -oE 'Key=ExpiresAt,Value=[0-9T:-]+Z' "$LOG" | cut -d= -f3)" &&
    grep -qxF 'Persistent=true' "$LOG" && grep -qxF 'ExecStart=/usr/bin/systemctl poweroff' "$LOG" &&
    grep -qxF 'systemctl enable --now forge-perf-expire.timer' "$LOG" &&
    grep -qxF "git -C /opt/forge-perf checkout --detach $sha" "$LOG" &&
    grep -qx 'i-0scratch' "$work/out" &&
    echo "ok: up launches a tagged box from the pinned AMI, with a poweroff timer at ExpiresAt that survives reboots" || fail "up: request differs"
fi

if run 0 "up in the forge-perf subnet" env FP_SUBNET=subnet-forgeperf bash "$script" up --ref "$sha"; then
  has subnet-forgeperf && ! has subnet-default2a && has --associate-public-ip-address &&
    in_call run-instances --security-group-ids sg-vpc-default &&
    echo "ok: in the forge-perf subnet, which assigns no public address, up asks for one and uses the default VPC's group" ||
    fail "up in the forge-perf subnet"
fi

if run 0 "group follows the subnet's VPC" env FP_SUBNET=subnet-forgeperf FP_VPC=vpc-other bash "$script" up --ref "$sha"; then
  has Name=vpc-id,Values=vpc-other && in_call run-instances --security-group-ids sg-vpc-other &&
    echo "ok: up takes the group from the VPC of the subnet it launches into" ||
    fail "group follows the subnet's VPC"
fi

if run 1 "no security group" env NO_SG=1 bash "$script" up --ref "$sha"; then
  ! has run-instances && grep -q 'no forge-perf-scratch security group in vpc-default' "$work/out" &&
    echo "ok: up without the forge-perf-scratch group is refused before launching" || fail "no security group"
fi
if run 1 "no deny policy" env NO_DENY=1 bash "$script" up --ref "$sha"; then
  ! has run-instances && grep -q 'no deny-parameter-reads policy' "$work/out" &&
    echo "ok: up with a role that can read parameters is refused before launching" || fail "no deny policy"
fi

if run 1 "hours out of range" bash "$script" up --hours 30 --ref "$sha"; then
  [ ! -s "$LOG" ] && echo "ok: more than 24 hours is refused before any AWS call" || fail "hours: called aws"
fi
if run 1 "short ref" bash "$script" up --ref abc123; then
  [ ! -s "$LOG" ] && echo "ok: a short ref is refused" || fail "short ref: called aws"
fi
if run 1 "no profile" env -u SCRATCH_INSTANCE_PROFILE bash "$script" up --ref "$sha"; then
  echo "ok: up without an instance profile is refused"
fi

printf 'i-0aaa\ti-0bbb\n' >"$work/instances"
if run 0 "down" bash "$script" down; then
  has Name=tag:Box,Values=scratch && has Name=tag:Project,Values=forge-perf && has i-0aaa && has i-0bbb &&
    has terminate-instances && echo "ok: down terminates only tagged scratch boxes" || fail "down"
fi
rm -f "$work/instances"
if run 0 "down, none" bash "$script" down; then
  ! has terminate-instances && echo "ok: down with no scratch boxes terminates nothing" || fail "down, none"
fi

if [ "$failures" -ne 0 ]; then
  echo "scratch_box_test: $failures failure(s)"
  exit 1
fi
echo "scratch_box_test: all passed"
