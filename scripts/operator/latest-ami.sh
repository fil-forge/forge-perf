#!/usr/bin/env bash
# Print Canonical's newest Ubuntu 24.04 server image (gp3) in us-east-2, for a
# pull request that moves ami_id in terraform/modules/shared/constants.
#
# A new image is a new kernel, which is an instrument change: the pull request
# replaces the persistent box and the page marks the change.
#
# Usage:
#   scripts/operator/latest-ami.sh [arm64|amd64]
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

ARCH="${1:-arm64}"
case "$ARCH" in arm64 | amd64) ;; *) die "usage: latest-ami.sh [arm64|amd64]" ;; esac

require aws
read -r id name created < <(aws ec2 describe-images --region "$REGION" --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-$ARCH-server-*" \
  Name=state,Values=available \
  --query 'sort_by(Images, &CreationDate)[-1].[ImageId, Name, CreationDate]' --output text)
[[ "${id:-}" =~ ^ami-[0-9a-f]+$ ]] || die "no image found"

echo "$id  $name  $created"
pinned="$(grep -oE 'ami-[0-9a-f]+' "$(dirname "$(readlink -f "$0")")/../../terraform/modules/shared/constants/outputs.tf" | head -1)"
if [ "$pinned" = "$id" ]; then
  echo "already pinned"
else
  echo "pinned: $pinned; set ami_id to $id and name the release ${name##*-} in its description"
fi
