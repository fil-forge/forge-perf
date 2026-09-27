#!/usr/bin/env bash
# Bring the box to the state this checkout describes: packages and pins, OS
# drift controls, kernel modules, Docker's configuration and the NVMe unit.
#
# Run once by the cloud-init bootstrap, and again between runs whenever host/
# or this script changes. Idempotent: a second run with nothing new changes
# nothing, restarts nothing, and says "0 change(s)". It never runs during a
# run, because a Docker change restarts the daemon.
#
# With FORGE_PERF_HOST_OPS=skip every host operation is logged and skipped
# (docs/runner.md, "Local run").
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

forge_perf_init
src="$FORGE_PERF_CHECKOUT/host"
changes=0
docker_changed=0

case "$(uname -m)" in
  aarch64 | arm64) platform=linux_arm64 ;;
  x86_64) platform=linux_amd64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac
host_ops_skipped || [ "$platform" = "$TARGET_PLATFORM" ] ||
  die "host is $platform, pins are for $TARGET_PLATFORM"

# put <mode> <source> <dest>: install a file when it differs; 0 when it did.
put() {
  if host_file "$1" "$3" <"$2"; then
    echo "  updated $3"
    changes=$((changes + 1))
    return 0
  fi
  return 1
}

installed_version() {
  # shellcheck disable=SC2016 # a dpkg-query format, not shell
  host_read dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

export DEBIAN_FRONTEND=noninteractive
# Waits up to five minutes for the dpkg lock instead of failing at once.
apt_get() { host_op apt-get -o DPkg::Lock::Timeout=300 "$@"; }
# apt-get update takes the lists lock, which DPkg::Lock::Timeout does not cover,
# so it retries for 5 minutes while an apt-daily run already under way holds it.
apt_update() {
  local tries=0
  until apt_get update -q; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || return 1
    sleep 10
  done
}

# First, so no apt-daily run starts while this script uses apt. One already
# running holds apt's locks, which apt_get and apt_update wait for.
step "OS drift controls"
# Timers that do disk or CPU work at random times. logrotate and tmpfiles stay.
for t in apt-daily.timer apt-daily-upgrade.timer fstrim.timer man-db.timer motd-news.timer \
  e2scrub_all.timer fwupd-refresh.timer dpkg-db-backup.timer ua-timer.timer \
  update-notifier-download.timer update-notifier-motd.timer; do
  if host_check systemctl is-enabled --quiet "$t" 2>/dev/null; then
    host_op systemctl disable --now "$t"
    changes=$((changes + 1))
  fi
done
# nvme-cli's nvmf-autoconnect.service tries NVMe-oF connections on every boot.
for s in apt-daily.service apt-daily-upgrade.service nvmf-autoconnect.service; do
  if [ "$(host_read systemctl is-enabled "$s" 2>/dev/null || true)" != masked ]; then
    host_op systemctl mask "$s"
    changes=$((changes + 1))
  fi
done
if [ -n "$(installed_version unattended-upgrades)" ]; then
  host_op systemctl disable --now unattended-upgrades.service
  apt_get purge -y -q unattended-upgrades
  changes=$((changes + 1))
fi
put 0644 "$src/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades || true
kernel="$(uname -r)"
holds="$(host_read apt-mark showhold)"
for p in linux-aws linux-image-aws linux-headers-aws "linux-image-$kernel"; do
  if [ -n "$(installed_version "$p")" ] && ! grep -qxF "$p" <<<"$holds"; then
    host_op apt-mark hold "$p" >/dev/null
    changes=$((changes + 1))
  fi
done
# Holds every snap, the SSM agent included; a refresh is a recorded box change.
# On first boot snapd may still be seeding, and refuses the hold until it is done.
host_op snap wait system seed.loaded
host_op snap refresh --hold >/dev/null

step "archive packages"
# shellcheck disable=SC2086 # a list of names
missing=$(for p in $ARCHIVE_PACKAGES; do [ -n "$(installed_version "$p")" ] || echo "$p"; done)
if [ -n "$missing" ]; then
  apt_update
  # shellcheck disable=SC2086
  apt_get install -y -q --no-install-recommends $missing
  changes=$((changes + 1))
fi

step "Docker CE $DOCKER_CE_VERSION"
if ! host_ops_skipped; then
  key="$(mktemp)"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key"
  # The fingerprint of every primary key in the file: apt trusts them all, so
  # the file must hold exactly Docker's.
  fpr="$(gpg --show-keys --with-colons "$key" |
    awk -F: '$1 == "pub" { p = 1; next } p && $1 == "fpr" { print $10; p = 0 }' | paste -sd, -)"
  [ "$fpr" = "$DOCKER_APT_KEY_FPR" ] || die "Docker's apt key is $fpr, expected $DOCKER_APT_KEY_FPR"
  put 0644 "$key" /etc/apt/keyrings/docker.asc || true
  rm -f "$key"
fi
repo="$(mktemp)"
echo "deb [arch=${TARGET_PLATFORM#linux_} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" >"$repo"
put 0644 "$repo" /etc/apt/sources.list.d/docker.list || true
rm -f "$repo"

want=(docker-ce="$DOCKER_CE_VERSION" docker-ce-cli="$DOCKER_CE_VERSION"
  containerd.io="$CONTAINERD_VERSION" docker-compose-plugin="$COMPOSE_PLUGIN_VERSION")
stale=()
for pv in "${want[@]}"; do
  [ "$(installed_version "${pv%%=*}")" = "${pv#*=}" ] || stale+=("$pv")
done
if [ "${#stale[@]}" -gt 0 ]; then
  # Update first: on a new box apt has not read docker.list yet, and apt-mark
  # fails on a package it knows nothing about.
  apt_update
  host_op apt-mark unhold "${want[@]%%=*}" >/dev/null
  # No recommends: they (buildx, rootless extras, pigz) would arrive unpinned.
  apt_get install -y -q --no-install-recommends --allow-downgrades "${want[@]}"
  host_op apt-mark hold "${want[@]%%=*}" >/dev/null
  changes=$((changes + 1))
  docker_changed=1
fi

step "kernel modules"
for m in sch_netem sch_prio cls_u32; do
  host_op modprobe "$m" ||
    { apt_get install -y -q "linux-modules-extra-$kernel" && host_op modprobe "$m"; } ||
    die "kernel module $m is not available for $kernel"
done
mods="$(mktemp)"
printf '%s\n' sch_netem sch_prio cls_u32 >"$mods"
put 0644 "$mods" /etc/modules-load.d/forge-perf.conf || true
rm -f "$mods"

step "journald"
if put 0644 "$src/journald/forge-perf.conf" /etc/systemd/journald.conf.d/forge-perf.conf; then
  host_op systemctl restart systemd-journald
fi

step "Docker and the NVMe unit"
put 0644 "$src/docker/daemon.json" /etc/docker/daemon.json && docker_changed=1
put 0644 "$src/docker/forge-perf.conf" /etc/systemd/system/docker.service.d/forge-perf.conf && docker_changed=1
put 0644 "$FORGE_PERF_CHECKOUT/systemd/forge-perf-nvme.service" \
  /etc/systemd/system/forge-perf-nvme.service && docker_changed=1
host_op install -d -m 0755 "$R/etc/forge-perf" "$R$FORGE_PERF_STATE_DIR" "$R/var/cache/forge-perf/go"

# Installing Docker starts it before the drop-in and the NVMe unit exist, on
# root's volumes/ directory. Stop it, socket first so nothing reactivates it,
# then bring up the NVMe and Docker in that order.
if [ "$docker_changed" -eq 1 ] || ! host_check systemctl is-active --quiet forge-perf-nvme.service; then
  host_op systemctl stop docker.socket docker.service
  host_op systemctl daemon-reload
  host_op systemctl enable forge-perf-nvme.service
  host_op systemctl start forge-perf-nvme.service
  host_op systemctl start docker.service
fi

tools="$("$FORGE_PERF_CHECKOUT/scripts/host/install-tools.sh")" || die "install-tools.sh failed"
printf '%s\n' "$tools"
changes=$((changes + $(grep -c '^  installed ' <<<"$tools" || true)))

step "provisioned: $changes change(s)"
