#!/usr/bin/env bash
# Hold a box, or release it, over SSM Run Command.
#
#   scripts/operator/hold.sh main on    no run starts; returns once the box is idle
#   scripts/operator/hold.sh main off   runs start again at the next poll
#
# `on` sets the hold at once, so no new run starts, then waits for a run
# already going to finish, up to 7 hours. The hold survives a reboot.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

BOX="${1:-}"
case "${2:-}" in
  on) command=(hold --wait-idle) ;;
  off) command=(release) ;;
  *) die "usage: hold.sh <box> on|off" ;;
esac
TIMEOUT_SECONDS=25200
WAIT_SECONDS="${HOLD_WAIT_SECONDS:-$((TIMEOUT_SECONDS + 60))}"
POLL_SECONDS="${HOLD_POLL_SECONDS:-15}"

require aws
INSTANCE_ID="$(box_instance_id "$BOX")"

COMMAND_ID="$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --comment "forge-perf hold $2 on $BOX" \
  --parameters "commands=[\"/opt/forge-perf/scripts/host/status.sh ${command[*]}\"],executionTimeout=[\"$TIMEOUT_SECONDS\"]" \
  --query Command.CommandId --output text)"
echo "status.sh ${command[*]} on box '$BOX' ($INSTANCE_ID), command $COMMAND_ID" >&2

deadline=$((SECONDS + WAIT_SECONDS))
while :; do
  status="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)"
  case "$status" in
    Pending | InProgress | Delayed) ;;
    *) break ;;
  esac
  [ "$SECONDS" -lt "$deadline" ] || die "still $status after ${WAIT_SECONDS}s; command $COMMAND_ID"
  sleep "$POLL_SECONDS"
done

aws ssm get-command-invocation --region "$REGION" \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text
[ "$status" = Success ] || die "status.sh ended $status"
