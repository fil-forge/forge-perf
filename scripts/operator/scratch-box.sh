#!/usr/bin/env bash
# A throwaway box for trying host provisioning on real hardware.
#
#   scratch-box.sh up [--type m9gd.2xlarge] [--hours 4] [--ref <commit>]
#   scratch-box.sh down
#
# `up` launches one instance from the pinned AMI, tagged Project=forge-perf,
# Box=scratch and ExpiresAt, whose user data clones this repository at --ref
# (default: this checkout's HEAD, which must be pushed) and runs provision.sh.
# The instance powers itself off at ExpiresAt, through a persistent systemd
# timer that survives reboots and fires at boot once the time has passed, and
# terminates on poweroff, so a forgotten scratch box stops costing money on
# its own. `down` terminates every scratch box. Open a shell with
# `aws ssm start-session --target <instance-id>`.
#
# Needs AWS credentials for the dev account and SCRATCH_INSTANCE_PROFILE, an
# instance profile carrying AmazonSSMManagedInstanceCore whose role also has
# the deny-parameter-reads policy; `up` refuses a role without it. The instance
# lands in the forge-perf subnet when it exists, else the default subnet of
# us-east-2a, with a public IPv4 address either way: the forge-perf subnet
# assigns none, and the box needs one to reach apt, GitHub and Session Manager
# without a NAT. Its only security group is forge-perf-scratch in that subnet's
# VPC, which admits no inbound traffic. docs/operations.md, "The scratch box's
# instance profile", creates the profile and the group.
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

repo="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
region=us-east-2
# shellcheck disable=SC2054 # each element is one comma-separated EC2 filter
filters=(Name=tag:Project,Values=forge-perf Name=tag:Box,Values=scratch)

up() {
  local type=m9gd.2xlarge hours=4 ref="" ami subnet vpc sg role at expires expires_cal user_data
  while [ $# -gt 0 ]; do
    case "$1" in
      --type) type="$2"; shift 2 ;;
      --hours) hours="$2"; shift 2 ;;
      --ref) ref="$2"; shift 2 ;;
      *) die "unknown argument $1" ;;
    esac
  done
  [[ "$hours" =~ ^[0-9]+$ ]] && [ "$hours" -ge 1 ] && [ "$hours" -le 24 ] || die "--hours takes 1 to 24"
  : "${SCRATCH_INSTANCE_PROFILE:?set SCRATCH_INSTANCE_PROFILE to an instance profile with SSM access}"
  [ -n "$ref" ] || ref="$(git -C "$repo" rev-parse HEAD)"
  [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || die "--ref must be a full commit SHA"

  ami="$(grep -oE 'ami-[0-9a-f]+' "$repo/terraform/modules/shared/constants/outputs.tf" | head -1)"
  [ -n "$ami" ] || die "no ami_id in the constants module"

  # The managed policy alone reads every parameter in the account.
  role="$(aws iam get-instance-profile --instance-profile-name "$SCRATCH_INSTANCE_PROFILE" \
    --query 'InstanceProfile.Roles[0].RoleName' --output text)"
  aws iam get-role-policy --role-name "$role" --policy-name deny-parameter-reads >/dev/null 2>&1 ||
    die "role $role has no deny-parameter-reads policy; see docs/operations.md"

  read -r subnet vpc < <(aws ec2 describe-subnets --region "$region" --filters Name=tag:Name,Values=forge-perf \
    --query 'Subnets[0].[SubnetId,VpcId]' --output text)
  if [ -z "$subnet" ] || [ "$subnet" = None ]; then
    read -r subnet vpc < <(aws ec2 describe-subnets --region "$region" \
      --filters Name=default-for-az,Values=true Name=availability-zone,Values="${region}a" \
      --query 'Subnets[0].[SubnetId,VpcId]' --output text)
  fi
  sg="$(aws ec2 describe-security-groups --region "$region" \
    --filters Name=group-name,Values=forge-perf-scratch Name=vpc-id,Values="$vpc" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  [ -n "$sg" ] && [ "$sg" != None ] || die "no forge-perf-scratch security group in $vpc; see docs/operations.md"
  # One instant for the tag and the timer. GNU date reads @<epoch>, BSD date -r.
  at=$(($(date -u +%s) + hours * 3600))
  expires="$(date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ)"
  expires_cal="$(date -u -d "@$at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$at" '+%Y-%m-%d %H:%M:%S')"

  user_data="$(cat <<USERDATA
#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/forge-perf-bootstrap.log) 2>&1
cat > /etc/systemd/system/forge-perf-expire.service <<'UNIT'
[Unit]
Description=Power off the scratch box at its ExpiresAt time

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl poweroff
UNIT
cat > /etc/systemd/system/forge-perf-expire.timer <<'UNIT'
[Unit]
Description=Power off the scratch box at its ExpiresAt time

[Timer]
OnCalendar=$expires_cal UTC
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now forge-perf-expire.timer
export DEBIAN_FRONTEND=noninteractive
apt-get update -q && apt-get install -y -q git
git clone --no-checkout https://github.com/fil-forge/forge-perf.git /opt/forge-perf
git -C /opt/forge-perf checkout --detach $ref
install -d -m 0755 /etc/forge-perf
printf '%s\n' FORGE_PERF_BOX_ID=scratch FORGE_PERF_CHECKOUT=/opt/forge-perf \
  FORGE_PERF_REF=$ref FORGE_PERF_MODE=scratch > /etc/forge-perf/box.conf
/opt/forge-perf/scripts/host/provision.sh
date -Is > /etc/forge-perf/bootstrap-complete
USERDATA
)"

  aws ec2 run-instances --region "$region" \
    --image-id "$ami" --instance-type "$type" --subnet-id "$subnet" --associate-public-ip-address \
    --security-group-ids "$sg" \
    --iam-instance-profile Name="$SCRATCH_INSTANCE_PROFILE" \
    --instance-initiated-shutdown-behavior terminate \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=100,VolumeType=gp3,DeleteOnTermination=true}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=forge-perf},{Key=Box,Value=scratch},{Key=Name,Value=forge-perf-scratch},{Key=ExpiresAt,Value=$expires}]" \
      "ResourceType=volume,Tags=[{Key=Project,Value=forge-perf},{Key=Box,Value=scratch}]" \
    --user-data "$user_data" \
    --query 'Instances[0].InstanceId' --output text
  echo "scratch box up until $expires; provisioning log: /var/log/forge-perf-bootstrap.log" >&2
}

down() {
  local ids
  ids="$(aws ec2 describe-instances --region "$region" \
    --filters "${filters[@]}" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  if [ -z "$ids" ]; then
    echo "no scratch boxes"
    return 0
  fi
  # shellcheck disable=SC2086 # a list of IDs
  aws ec2 terminate-instances --region "$region" --instance-ids $ids --output text >/dev/null
  echo "terminating $ids"
}

case "${1:-}" in
  up) shift; up "$@" ;;
  down) down ;;
  *) die "usage: scratch-box.sh up [--type T] [--hours N] [--ref SHA] | down" ;;
esac
