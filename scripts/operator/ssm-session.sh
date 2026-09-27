#!/usr/bin/env bash
# Open a shell on a box.
#
# There is no SSH on these boxes: no inbound port, no key pair, no bastion.
# Session Manager is the only way in, and it works because the SSM agent dials
# out. Needs the Session Manager plugin for the AWS CLI.
#
# Usage:
#   scripts/operator/ssm-session.sh main
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

BOX="${1:?usage: ssm-session.sh <box>}"

require aws
INSTANCE_ID="$(box_instance_id "$BOX")"

echo "Opening a session on box '$BOX' ($INSTANCE_ID)."
echo "The host scripts live in /opt/forge-perf/scripts/host and want root:"
echo "  sudo -i"
echo

# The session starts as ssm-user; the checkout, Docker and the run state are
# root's.
exec aws ssm start-session --region "$REGION" --target "$INSTANCE_ID"
