#!/usr/bin/env bash
# Shared helpers for the scripts an operator runs from their own machine,
# with their own AWS credentials for the dev account. Sourced, never executed.

# shellcheck shell=bash

REGION=us-east-2

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null || die "$1 is not installed"
}

box_name_ok() {
  [[ "$1" =~ ^[a-z0-9]{2,12}$ ]] || die "box name '$1' is not 2 to 12 lowercase letters or digits"
}

# The one running instance tagged Project=forge-perf and Box=<box>. Found by
# tag rather than from OpenTofu state, so the campaign box, whose root an
# operator has usually not initialised, is reached the same way as main.
box_instance_id() {
  local box="$1" ids
  box_name_ok "$box"
  ids="$(aws ec2 describe-instances --region "$REGION" \
    --filters Name=tag:Project,Values=forge-perf "Name=tag:Box,Values=$box" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  case "$(wc -w <<<"$ids" | tr -d ' ')" in
    1) echo "$ids" ;;
    0) die "no running box '$box'" ;;
    *) die "more than one running box '$box': $ids" ;;
  esac
}

# The one instance of a box, woken if it is asleep. A sleeping box is a
# stopped instance, so this starts it, first waiting out a stop still under
# way, then waits until it is running and its agent is Online in Session
# Manager, which comes some time after running and is what Run Command and a
# session need. Progress goes to stderr and the ID alone to stdout.
#
# Only a box that sleeps is started. A stopped box with an ExpiresAt tag (a
# campaign or scratch box; the persistent box never carries one) powered off
# because its runs ended, failed or ran out of time, and a campaign box
# resumes its runs at every boot, so starting one is refused.
# BOX_WAKE_WAIT_SECONDS (default 600) bounds the wait and
# BOX_WAKE_POLL_SECONDS (default 10) spaces the checks.
box_wake() {
  local box="$1" wait="${BOX_WAKE_WAIT_SECONDS:-600}" poll="${BOX_WAKE_POLL_SECONDS:-10}"
  local found ids state expires ping said="" started="" deadline
  box_name_ok "$box"
  deadline=$((SECONDS + wait))
  while :; do
    # A command substitution does not inherit errexit, so each call that must
    # succeed says so.
    found="$(aws ec2 describe-instances --region "$REGION" \
      --filters Name=tag:Project,Values=forge-perf "Name=tag:Box,Values=$box" Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query "Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key=='ExpiresAt']|[0].Value]" --output text)" ||
      die "could not look up box '$box'"
    ids="$(awk '{print $1}' <<<"$found" | xargs)"
    case "$(wc -w <<<"$ids" | tr -d ' ')" in
      1) ;;
      0) die "no running box '$box', and none stopped to start" ;;
      *) die "more than one box '$box': $ids" ;;
    esac
    state="$(awk '{print $2}' <<<"$found")"
    # Text output prints a missing tag as None.
    expires="$(awk '{print $3}' <<<"$found")"
    case "$state" in
      running)
        # A check that fails (credentials without the permission, say) is
        # told apart from an agent that is not up yet, with AWS's own error.
        if ping="$(aws ssm describe-instance-information --region "$REGION" --filters "Key=InstanceIds,Values=$ids" \
          --query 'InstanceInformationList[0].PingStatus' --output text 2>&1)"; then
          [ "$(tail -1 <<<"$ping")" != Online ] || break
          state="running but not online in Session Manager"
        else
          state="running, and its Session Manager status could not be read: $(tail -1 <<<"$ping")"
        fi
        ;;
      stopped)
        case "$expires" in
          None | "") ;;
          *) die "box '$box' ($ids) is stopped; it powered off when its runs ended or at its ExpiresAt, and only a box that sleeps is woken" ;;
        esac
        # Once: EC2 can go on answering stopped for a moment after the start.
        if [ -z "$started" ]; then
          echo "box '$box' ($ids) is stopped; starting it" >&2
          aws ec2 start-instances --region "$REGION" --instance-ids "$ids" >/dev/null ||
            die "could not start box '$box' ($ids)"
          started=1 said="$state"
        fi
        ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || die "box '$box' ($ids) is $state after ${wait}s"
    [ "$state" = "$said" ] || echo "box '$box' ($ids) is $state; waiting" >&2
    said="$state"
    sleep "$poll"
  done
  # box_instance_id has the last word, so a box that stopped again during the
  # wait is an error and not a stale ID.
  box_instance_id "$box"
}
