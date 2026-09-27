#!/usr/bin/env bash
# The cost backstop, run hourly by campaign-reaper.yml with the apply role.
#
# Every forge-perf instance other than the persistent box (Box=main) that is
# pending, running, stopping or stopped is reaped when it has no ExpiresAt
# tag, is stopped and past ExpiresAt, has been stopped for more than an hour,
# or is still up an hour after ExpiresAt. A box powers itself off at
# ExpiresAt; the hour covers one whose own poweroff failed. Every reaped
# instance is terminated here.
#
# Whether the campaign root is destroyed is decided from its state, every
# hour: CAMPAIGN_INSTANCE is the instance ID `tofu output` read from it (empty
# when the state holds no box). The root is destroyed when that instance is
# reaped now, or is already shutting down, terminated or gone, so a destroy
# that failed is tried again the next hour. A newer box that the state holds
# is never destroyed for an older one reaped here.
#
# The persistent box is never touched, but an instance type that differs from
# terraform/envs/box/main/terraform.tfvars is reported: a resize that never
# applied, or one made by hand. That line comes once a day, in the run in the
# 00:00 UTC hour, or on every run with REPORT_DRIFT=1, since a tier change
# holds the difference until its apply is approved.
#
# Prints one line per finding, and with GITHUB_OUTPUT set writes `campaign`
# (the instance ID when the campaign root must be destroyed, else false) and `alerts` (the lines, for
# Slack). NOW (Unix seconds) replaces the clock in tests.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

repo="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
now="${NOW:-$(date -u +%s)}"
want_type="$(sed -nE 's/^instance_type[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
  "$repo/terraform/envs/box/main/terraform.tfvars")"
[ -n "$want_type" ] || die "no instance_type in terraform/envs/box/main/terraform.tfvars"

instances="$(aws ec2 describe-instances --region "$REGION" --output json \
  --filters Name=tag:Project,Values=forge-perf Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{id: InstanceId, type: InstanceType, state: State.Name,
    reason: StateTransitionReason, tags: Tags}')"

# id box why, one line per instance to reap; a box's stop time comes from
# StateTransitionReason, "User initiated (2026-09-26 10:00:00 GMT)".
# shellcheck disable=SC2016 # a jq program
reap="$(jq -r --argjson now "$now" '
  .[] | (reduce (.tags // [])[] as $t ({}; .[$t.Key] = $t.Value)) as $tags
  | select(($tags.Box // "") != "main")
  | ([$tags.ExpiresAt // "" | fromdateiso8601?] | first) as $expires
  | ([.reason // "" | capture("\\((?<t>[0-9-]+ [0-9:]+) GMT\\)")? | .t | strptime("%Y-%m-%d %H:%M:%S") | mktime]
     | first) as $stopped
  | (if $expires == null then "it has no ExpiresAt"
     elif .state == "stopped" and $expires <= $now then "it expired at \($tags.ExpiresAt)"
     elif $expires + 3600 <= $now then "it expired at \($tags.ExpiresAt) and is still \(.state)"
     elif .state == "stopped" and ($stopped == null or $now - $stopped > 3600) then "it has been stopped for over an hour"
     else empty end) as $why
  | "\(.id) \($tags.Box // "none") \($why)"' <<<"$instances")"

held="${CAMPAIGN_INSTANCE:-}"
[[ -z "$held" || "$held" =~ ^i-[0-9a-f]{8,17}$ ]] || die "CAMPAIGN_INSTANCE '$held' is not an instance ID"
alerts=() campaign=false terminate=()
while read -r id box why; do
  [ -n "$id" ] || continue
  terminate+=("$id")
  if [ "$id" = "$held" ]; then
    campaign="$held"
    alerts+=("forge-perf: terminating and destroying the campaign box $id: $why")
  else
    alerts+=("forge-perf: terminating the $box box $id: $why")
  fi
done <<<"$reap"

# The state's instance, when this pass did not reap it: gone already means an
# earlier destroy failed or never ran.
if [ -n "$held" ] && [ "$campaign" = false ]; then
  err="$(mktemp)"
  if held_state="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$held" \
    --query 'Reservations[].Instances[].State.Name' --output text 2>"$err")"; then
    rm -f "$err"
  elif grep -q InvalidInstanceID.NotFound "$err"; then
    rm -f "$err"
    held_state=gone
  else
    cat "$err" >&2
    rm -f "$err"
    die "cannot read the state of the campaign box $held"
  fi
  case "$held_state" in
    shutting-down | terminated | gone | "")
      campaign="$held"
      alerts+=("forge-perf: destroying the campaign root; its box $held is ${held_state:-gone}") ;;
  esac
fi

# shellcheck disable=SC2016 # a jq program
main_type="$(jq -r '[.[] | select(any(.tags[]?; .Key == "Box" and .Value == "main")) | .type] | unique | join(" ")' \
  <<<"$instances")"
if [ -n "$main_type" ] && [ "$main_type" != "$want_type" ] &&
  { [ "${REPORT_DRIFT:-}" = 1 ] || [ $((now / 3600 % 24)) -eq 0 ]; }; then
  alerts+=("forge-perf: the persistent box is $main_type; terraform.tfvars says $want_type")
fi

if [ "${#terminate[@]}" -gt 0 ]; then
  aws ec2 terminate-instances --region "$REGION" --instance-ids "${terminate[@]}" --output text >/dev/null
fi
[ "${#alerts[@]}" -eq 0 ] || printf '%s\n' "${alerts[@]}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "campaign=$campaign"
    echo "alerts<<ALERTS"
    [ "${#alerts[@]}" -eq 0 ] || printf '%s\n' "${alerts[@]}"
    echo "ALERTS"
  } >>"$GITHUB_OUTPUT"
fi
