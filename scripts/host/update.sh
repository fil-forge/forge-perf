#!/usr/bin/env bash
# Move the box to the newest commit of the ref it tracks, and bring the host
# to what that commit describes.
#
#   update.sh           fetch and reset to origin/<ref>, then as --local
#   update.sh --local   no fetch: provision this checkout if it is not yet,
#                       sync the systemd units, enable the units of this box's
#                       mode (the first-boot bootstrap, on any mode)
#
# provision.sh runs when the checkout's host/ or provisioning scripts differ
# from the commit provisioning last succeeded at, recorded in the state
# directory, or when there is no such record. A failed provision leaves the
# record alone, so the next pass tries again.
#
# Run between runs by poll.sh, and by an operator through
# scripts/operator/box-update.sh. It refuses on a campaign box, which stays at
# its bootstrap commit; while a run holds the run lock or forge-perf-run is
# starting, running or stopping; and when the checkout has hand edits to
# tracked files, which the reset would discard. Modeled on infra-nodes'
# reconcile.sh.
set -euo pipefail

# The reset below replaces this file while bash is still reading it, so run
# from a copy. Through the interpreter, since /run may be mounted noexec.
if [ -z "${FORGE_PERF_UPDATE_COPY:-}" ]; then
  copy_dir="$(mktemp -d "${FORGE_PERF_COPY_DIR:-/run}/forge-perf-update.XXXXXX")"
  cp -a "$(dirname "$(readlink -f "$0")")/." "$copy_dir/"
  FORGE_PERF_UPDATE_COPY="$copy_dir" exec "$BASH" "$copy_dir/update.sh" "$@"
fi
trap 'rm -rf "$FORGE_PERF_UPDATE_COPY"' EXIT

# shellcheck source=lib.sh
. "$FORGE_PERF_UPDATE_COPY/lib.sh"

local_only=0
case "${1:-}" in
  "") ;;
  --local) local_only=1 ;;
  *) die "usage: update.sh [--local]" ;;
esac

forge_perf_init
mode="${FORGE_PERF_MODE:-persistent}"
ref="${FORGE_PERF_REF:-main}"
git=(git -C "$FORGE_PERF_CHECKOUT")
provisioned_rev="$FORGE_PERF_STATE_DIR/provisioned-rev"

if [ "$local_only" -eq 0 ]; then
  [ "$mode" != campaign ] || die "a campaign box stays at its bootstrap commit"

  # poll.sh already holds the run lock and says so; anyone else takes it here
  # and keeps it until exit, so no run starts from a half-updated checkout.
  if [ -z "${FORGE_PERF_LOCK_HELD:-}" ] && command -v flock >/dev/null; then
    runtime="${FORGE_PERF_RUNTIME:-/run/forge-perf}"
    mkdir -p "$runtime"
    exec 9>"$runtime/run.lock"
    flock -n 9 || die "a run holds $runtime/run.lock; update after it"
  fi
  # The unit is Type=oneshot: activating while it runs and deactivating while
  # its ExecStopPost wipes, states `systemctl is-active` reports as inactive.
  run_state="$(host_read systemctl show -p ActiveState --value forge-perf-run.service)"
  case "$run_state" in
    active | activating | deactivating | reloading)
      die "forge-perf-run.service is $run_state; update after it" ;;
  esac

  step "update $FORGE_PERF_CHECKOUT to $ref"
  if ! "${git[@]}" diff --quiet || ! "${git[@]}" diff --cached --quiet; then
    "${git[@]}" status --short --untracked-files=no >&2
    die "$FORGE_PERF_CHECKOUT has hand edits to tracked files; not updating"
  fi
  before="$("${git[@]}" rev-parse HEAD)"
  "${git[@]}" fetch --quiet --force origin
  # origin/<ref> for a branch; a commit has no origin/ form.
  "${git[@]}" reset --quiet --hard "origin/$ref" 2>/dev/null ||
    "${git[@]}" reset --quiet --hard "$ref"
  after="$("${git[@]}" rev-parse HEAD)"
  if [ "$before" = "$after" ]; then
    echo "  already at ${after:0:12}"
  else
    echo "  ${before:0:12} -> ${after:0:12}"
  fi
fi

# Compared against the last successful provision rather than this pass's
# starting commit, as infra-nodes' reconcile does with its deployed revision.
head="$("${git[@]}" rev-parse HEAD)"
last="$(cat "$R$provisioned_rev" 2>/dev/null || true)"
provision=0
if [ -z "$last" ] || ! "${git[@]}" cat-file -e "$last^{commit}" 2>/dev/null; then
  provision=1
elif [ -n "$("${git[@]}" diff --name-only "$last" "$head" -- \
  host scripts/host/provision.sh scripts/host/install-tools.sh)" ]; then
  provision=1
fi
if [ "$provision" -eq 1 ]; then
  step "host/ or provisioning differs from the last provision: provision.sh"
  "$FORGE_PERF_CHECKOUT/scripts/host/provision.sh"
  printf '%s\n' "$head" | host_file 0644 "$provisioned_rev" || true
fi

step "systemd units"
sync_systemd_units
enable_mode_units "$mode"
step "updated"
