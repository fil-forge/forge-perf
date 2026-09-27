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

# The one running instance tagged Project=forge-perf and Box=<box>. Found by
# tag rather than from OpenTofu state, so the campaign box, whose root an
# operator has usually not initialised, is reached the same way as main.
box_instance_id() {
  local box="$1" ids
  [[ "$box" =~ ^[a-z0-9]{2,12}$ ]] || die "box name '$box' is not 2 to 12 lowercase letters or digits"
  ids="$(aws ec2 describe-instances --region "$REGION" \
    --filters Name=tag:Project,Values=forge-perf "Name=tag:Box,Values=$box" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  case "$(wc -w <<<"$ids" | tr -d ' ')" in
    1) echo "$ids" ;;
    0) die "no running box '$box'" ;;
    *) die "more than one running box '$box': $ids" ;;
  esac
}
