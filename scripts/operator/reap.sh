#!/usr/bin/env bash
# The cost backstop, run hourly by campaign-reaper.yml with the apply role.
#
# Every forge-perf instance other than the persistent box (Box=main) that is
# pending, running, stopping or stopped is reaped once it is past its
# ExpiresAt tag, has none, or has been stopped for more than an hour. A
# campaign box is left to `tofu destroy` of its root, which also removes its
# buckets; any other box, such as a scratch box, is terminated here. The
# persistent box is never touched, but an instance type that differs from
# terraform/envs/box/main/terraform.tfvars is reported: a resize that never
# applied, or one made by hand.
#
# Prints one line per finding, and with GITHUB_OUTPUT set writes `campaign`
# (true when the campaign root must be destroyed) and `alerts` (the lines, for
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
     elif $expires <= $now then "it expired at \($tags.ExpiresAt)"
     elif .state == "stopped" and ($stopped == null or $now - $stopped > 3600) then "it has been stopped for over an hour"
     else empty end) as $why
  | "\(.id) \($tags.Box // "none") \($why)"' <<<"$instances")"

alerts=() campaign=false terminate=()
while read -r id box why; do
  [ -n "$id" ] || continue
  if [ "$box" = campaign ]; then
    campaign=true
    alerts+=("forge-perf: destroying the campaign box $id: $why")
  else
    terminate+=("$id")
    alerts+=("forge-perf: terminating the $box box $id: $why")
  fi
done <<<"$reap"

# shellcheck disable=SC2016 # a jq program
main_type="$(jq -r '[.[] | select(any(.tags[]?; .Key == "Box" and .Value == "main")) | .type] | unique | join(" ")' \
  <<<"$instances")"
if [ -n "$main_type" ] && [ "$main_type" != "$want_type" ]; then
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
