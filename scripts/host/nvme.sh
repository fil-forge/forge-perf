#!/usr/bin/env bash
# Prepare the instance-store NVMe for Docker's named volumes.
#
#   nvme.sh boot    run by forge-perf-nvme.service before docker.service
#
# Formats the device as ext4 with eager inode-table and journal init, so no
# ext4lazyinit thread writes across the drive during the next ingest, mounts it
# at $FORGE_PERF_NVME_MOUNT and binds its docker-volumes directory over
# /var/lib/docker/volumes. Neither mount goes in fstab: the device is blank
# after a stop, and a new format changes its UUID.
#
# One exception to formatting: after a plain reboot during a run
# ($FORGE_PERF_STATE_DIR/current.json exists) a device that already carries
# the forge-perf-nvme label is mounted as it is, so recovery can collect the
# interrupted run; if that mount fails, the device is formatted. Refuses to
# run while Docker is up.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

[ "${1:-}" = boot ] || die "usage: nvme.sh boot"

if host_check systemctl is-active --quiet docker.service; then
  die "docker.service is running; the NVMe is prepared only before Docker starts"
fi

dev="$(instance_store_dev)"
step "instance store $dev"

for m in "$FORGE_PERF_VOLUMES_DIR" "$FORGE_PERF_NVME_MOUNT"; do
  if host_check mountpoint -q "$m"; then
    host_op umount "$m"
  fi
done

host_op install -d "$FORGE_PERF_NVME_MOUNT"
mounted=0
label="$(host_read blkid -s LABEL -o value "$dev" || true)"
if [ "$label" = "$FORGE_PERF_NVME_LABEL" ] && [ -e "$FORGE_PERF_STATE_DIR/current.json" ]; then
  echo "a run was in progress; mounting without formatting"
  # A filesystem that no longer mounts has lost the run's evidence anyway.
  # Formatting lets Docker start, and recovery closes out the run.
  if host_op mount -o noatime "$dev" "$FORGE_PERF_NVME_MOUNT"; then
    mounted=1
  else
    echo "mount failed; formatting"
  fi
fi
if [ "$mounted" -eq 0 ]; then
  start=$SECONDS
  host_op mkfs.ext4 -F -q -m 0 -L "$FORGE_PERF_NVME_LABEL" \
    -E lazy_itable_init=0,lazy_journal_init=0 "$dev"
  echo "formatted $dev in $((SECONDS - start)) s"
  host_op mount -o noatime "$dev" "$FORGE_PERF_NVME_MOUNT"
fi
# 0701 is the mode Docker gives volumes/ itself.
host_op install -d -m 0701 "$FORGE_PERF_NVME_MOUNT/docker-volumes"
host_op install -d "$FORGE_PERF_NVME_MOUNT/work" "$FORGE_PERF_NVME_MOUNT/scratch" "$FORGE_PERF_VOLUMES_DIR"
host_op mount --bind "$FORGE_PERF_NVME_MOUNT/docker-volumes" "$FORGE_PERF_VOLUMES_DIR"
host_op sync
host_op sysctl -q vm.drop_caches=3
step "NVMe ready"
