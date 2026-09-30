#!/usr/bin/env bash
# Wake a sleeping box and print its instance ID.
#
# A box that sleeps when idle is a stopped instance. This starts it and
# returns once it is running and Online in Session Manager, up to 10 minutes.
# A box that is already up is left alone. The box goes back to sleep when it
# is next idle; `hold.sh <box> on` keeps it up.
#
# Usage:
#   scripts/operator/wake.sh main
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

BOX="${1:-}"
[ -n "$BOX" ] || die "usage: wake.sh <box>"

require aws
box_wake "$BOX"
