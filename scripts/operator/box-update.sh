#!/usr/bin/env bash
# Run update.sh on a box over SSM Run Command and print its output.
#
# The box moves its checkout to the newest commit of the ref it tracks,
# reruns provisioning when host/ changed, and syncs and enables its units.
# update.sh refuses while a run is in progress and on a campaign box; this
# script then exits non-zero with update.sh's message. A sleeping box is woken
# first.
#
# Usage:
#   scripts/operator/box-update.sh main
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

BOX="${1:?usage: box-update.sh <box>}"
# Provisioning after a Docker or Go bump can take several minutes. The default
# wait outlasts the command's own execution timeout below.
TIMEOUT_SECONDS=1800
WAIT_SECONDS="${BOX_UPDATE_WAIT_SECONDS:-$((TIMEOUT_SECONDS + 60))}"
# A command still Pending after this long is taken for one sent to a box that
# was powering off to sleep: EC2 and Session Manager go on reporting such a box
# as up for a moment. Waking the box again lets the command be delivered.
REWAKE_SECONDS="${BOX_PENDING_REWAKE_SECONDS:-60}"
POLL_SECONDS="${BOX_UPDATE_POLL_SECONDS:-5}"

require aws
INSTANCE_ID="$(box_wake "$BOX")"

COMMAND_ID="$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --comment "forge-perf update.sh on $BOX" \
  --parameters "commands=[\"/opt/forge-perf/scripts/host/update.sh\"],executionTimeout=[\"$TIMEOUT_SECONDS\"]" \
  --query Command.CommandId --output text)"
echo "update.sh on box '$BOX' ($INSTANCE_ID), command $COMMAND_ID" >&2

deadline=$((SECONDS + WAIT_SECONDS))
rewake_at=$((SECONDS + REWAKE_SECONDS))
while :; do
  status="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)"
  case "$status" in
    Pending | InProgress | Delayed) ;;
    *) break ;;
  esac
  [ "$SECONDS" -lt "$deadline" ] || die "still $status after ${WAIT_SECONDS}s; command $COMMAND_ID"
  if [ "$status" = Pending ] && [ "$SECONDS" -ge "$rewake_at" ]; then
    box_wake "$BOX" >/dev/null
    rewake_at=$((SECONDS + REWAKE_SECONDS))
  fi
  sleep "$POLL_SECONDS"
done

# Run Command keeps the first 24,000 characters of each stream.
aws ssm get-command-invocation --region "$REGION" \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text
[ "$status" = Success ] || die "update.sh ended $status"
