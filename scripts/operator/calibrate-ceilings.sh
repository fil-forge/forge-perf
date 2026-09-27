#!/usr/bin/env bash
# Measure one instance type's ceilings on the campaign box, bring the evidence
# into the repository and tear the box down (docs/operations.md, "Measuring
# the ceilings").
#
#   scripts/operator/calibrate-ceilings.sh <instance type> [--date YYYY-MM-DD] [--quick] [--keep]
#      [--workers N]
#
# The campaign box must be up in mode calibration with that type. The script
# waits for Session Manager to see it, runs scripts/host/ceiling.sh on it over
# SSM Run Command (4 hours at most), copies
# s3://<results bucket>/raw/calibration/<date>/<type>/ to
# calibration/ceilings/<date>/<type>/ and dispatches campaign.yml down. --quick
# runs the short check and copies to local/ceilings/ instead, which git
# ignores; --keep leaves the box up; --workers N replaces the main S3 phase's
# 8 workers per vCPU. After a failure the box stays up for a
# look, and powers off at its ExpiresAt.
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib.sh
. "$here/lib.sh"

type="${1:-}"
shift || true
date="$(date -u +%F)" quick="" keep="" workers=""
while [ $# -gt 0 ]; do
  case "$1" in
    --date) date="${2:-}"; shift ;;
    --quick) quick=1 ;;
    --keep) keep=1 ;;
    --workers) workers="${2:-}"; shift ;;
    *) die "usage: calibrate-ceilings.sh <instance type> [--date YYYY-MM-DD] [--quick] [--keep] [--workers N]" ;;
  esac
  shift
done
case "$type" in m9gd.2xlarge | m9gd.8xlarge | m9gd.16xlarge) ;; *) die "type is m9gd.2xlarge, m9gd.8xlarge or m9gd.16xlarge" ;; esac
[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date is YYYY-MM-DD"
[[ -z "$workers" || "$workers" =~ ^[1-9][0-9]{0,3}$ ]] || die "--workers takes 1 to 9999"

require aws
require jq
[ -n "$keep" ] || require gh
repo="$(cd "$here/../.." && pwd -P)"
results="${FORGE_PERF_RESULTS_BUCKET:-forge-perf-results-654654381893}"
poll="${CALIBRATE_POLL_SECONDS:-30}"
timeout=14400

id="$(box_instance_id campaign)"
got="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$id" \
  --query 'Reservations[0].Instances[0].InstanceType' --output text)"
[ "$got" = "$type" ] || die "the campaign box is $got, not $type; dispatch campaign.yml down, then up with $type"

deadline=$((SECONDS + 900))
until [ "$(aws ssm describe-instance-information --region "$REGION" --filters "Key=InstanceIds,Values=$id" \
  --query 'InstanceInformationList[0].PingStatus' --output text)" = Online ]; do
  [ "$SECONDS" -lt "$deadline" ] || die "$id is not online in Session Manager after 15 minutes"
  sleep "$poll"
done

cmd="/opt/forge-perf/scripts/host/ceiling.sh --date $date${quick:+ --quick}${workers:+ --workers $workers}"
command_id="$(aws ssm send-command --region "$REGION" --instance-ids "$id" \
  --document-name AWS-RunShellScript --comment "forge-perf ceilings $type $date" \
  --parameters "commands=[\"$cmd\"],executionTimeout=[\"$timeout\"]" \
  --query Command.CommandId --output text)"
echo "ceiling.sh on $type ($id), command $command_id; a full session takes 1 to 3 hours" >&2

deadline=$((SECONDS + timeout + 300))
while :; do
  status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$command_id" --instance-id "$id" \
    --query Status --output text 2>/dev/null || echo Pending)"
  case "$status" in
    Pending | InProgress | Delayed) ;;
    *) break ;;
  esac
  [ "$SECONDS" -lt "$deadline" ] || die "still $status; command $command_id"
  sleep "$poll"
done
aws ssm get-command-invocation --region "$REGION" --command-id "$command_id" --instance-id "$id" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text | tail -20
[ "$status" = Success ] || die "ceiling.sh ended $status; the box stays up until its ExpiresAt"

dest="$repo/calibration/ceilings/$date/$type"
[ -z "$quick" ] || dest="$repo/local/ceilings/$date/$type"
rm -rf "$dest"
mkdir -p "$dest"
aws s3 cp --recursive --only-show-errors "s3://$results/raw/calibration/$date/$type/" "$dest/"
[ -f "$dest/summary.json" ] || die "no summary.json under s3://$results/raw/calibration/$date/$type/"
jq -c '{instance_type, quick, ceiling, limited_by, s3_p5: .s3_put.p5, nvme_p5: .nvme_write.p5}' "$dest/summary.json"
echo "evidence in ${dest#"$repo"/}" >&2

if [ -z "$keep" ]; then
  gh workflow run campaign.yml -R fil-forge/forge-perf --ref main -f action=down -f instance_type="$type"
  echo "dispatched campaign.yml down; check that it completed (docs/operations.md, \"A campaign\")" >&2
fi
