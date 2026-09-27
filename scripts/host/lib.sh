#!/usr/bin/env bash
# Shared helpers for the scripts that run on a forge-perf box.
#
# Sourced, never executed. On the box these run as root. Every operation that
# changes or inspects the host itself (packages, mkfs, mount, sysctl,
# systemctl, kernel modules, files under /etc, instance metadata) goes through
# host_op, host_check or host_read, so that FORGE_PERF_HOST_OPS=skip turns the
# whole host layer into logged no-ops. That mode is for exercising the scripts
# on a laptop (docs/runner.md, "Local run"). It is refused under
# systemd and wherever instance metadata answers, so a stray setting on the box
# cannot turn off the NVMe format or provisioning.

# shellcheck shell=bash

FORGE_PERF_STATE_DIR="${FORGE_PERF_STATE_DIR:-/var/lib/forge-perf/state}"
FORGE_PERF_NVME_MOUNT="${FORGE_PERF_NVME_MOUNT:-/mnt/forge-perf/nvme}"
FORGE_PERF_VOLUMES_DIR="${FORGE_PERF_VOLUMES_DIR:-/var/lib/docker/volumes}"
# shellcheck disable=SC2034 # used by nvme.sh
FORGE_PERF_NVME_LABEL=forge-perf-nvme
# Prefix for the files the scripts install or read under /etc. Empty on the
# box; the tests point it at a scratch directory.
R="${FORGE_PERF_HOST_ROOT:-}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo "=== $* ==="
}

host_ops_skipped() {
  [ "${FORGE_PERF_HOST_OPS:-run}" = skip ]
}

# A command that changes the host. Skipped: logged, and reported as success.
host_op() {
  if host_ops_skipped; then
    echo "host-op skipped: $*" >&2
    return 0
  fi
  "$@"
}

# A command asked only for its exit status. Skipped: logged, and false, so a
# caller never acts on a fact it did not observe.
host_check() {
  if host_ops_skipped; then
    echo "host-check skipped: $*" >&2
    return 1
  fi
  "$@"
}

# A command asked for its output. Skipped: logged, and prints nothing.
host_read() {
  if host_ops_skipped; then
    echo "host-read skipped: $*" >&2
    return 0
  fi
  "$@"
}

# host_file <mode> <dest> < content: write a host file when its content
# differs. Returns 0 when it wrote (or would have, in skip mode), 1 when the
# file already matched; dies when the write fails.
host_file() {
  local mode="$1" dest="$R$2" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if ! host_ops_skipped && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  if ! host_op mkdir -p "$(dirname "$dest")" || ! host_op install -m "$mode" "$tmp" "$dest"; then
    die "cannot write $dest"
  fi
  rm -f "$tmp"
}

# Instance metadata over IMDSv2, e.g. `imds instance-type`. The box's type is
# read here rather than passed in user_data, so a resize changes no template.
imds() {
  local base="${FORGE_PERF_IMDS_URL:-http://169.254.169.254}" token
  if host_ops_skipped; then
    echo "host-read skipped: imds $1" >&2
    echo local
    return 0
  fi
  token="$(curl -fsS -m 5 -X PUT "$base/latest/api/token" \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" || die "IMDS token request failed"
  curl -fsS -m 5 -H "X-aws-ec2-metadata-token: $token" "$base/latest/meta-data/$1" ||
    die "IMDS has no $1"
}

# Load /etc/forge-perf/box.conf (or FORGE_PERF_BOX_CONF) and the pins.
forge_perf_init() {
  local conf="${FORGE_PERF_BOX_CONF:-/etc/forge-perf/box.conf}"
  if ! host_ops_skipped; then
    [ "$(id -u)" -eq 0 ] || die "must run as root"
  fi
  [ -r "$conf" ] || die "$conf is missing; cloud-init did not finish"
  # shellcheck disable=SC1090
  . "$conf"
  refuse_skip_on_box
  : "${FORGE_PERF_BOX_ID:?FORGE_PERF_BOX_ID not set in $conf}"
  : "${FORGE_PERF_CHECKOUT:?FORGE_PERF_CHECKOUT not set in $conf}"
  # shellcheck source=../../host/versions.env
  . "$FORGE_PERF_CHECKOUT/host/versions.env"
}

# The instance-store NVMe: the one whole disk whose model is Nitro's instance
# storage string. Not the /dev/disk/by-id glob, where systemd 255 may create two
# links per namespace. EBS volumes report "Amazon Elastic Block Store".
instance_store_dev() {
  local devs
  if host_ops_skipped; then
    echo "host-read skipped: lsblk" >&2
    echo /dev/forge-perf-local-nvme
    return 0
  fi
  devs="$(lsblk -dno PATH,MODEL |
    awk '{ path = $1; $1 = ""; sub(/^ +/, "") } $0 == "Amazon EC2 NVMe Instance Storage" { print path }')"
  if [ -z "$devs" ] || [ "$(wc -l <<<"$devs")" -ne 1 ]; then
    die "expected one instance-store NVMe, found $(grep -c . <<<"$devs" || true)"
  fi
  printf '%s\n' "$devs"
}

# Skip mode on the box would let Docker start on root's volumes/ directory.
refuse_skip_on_box() {
  host_ops_skipped || return 0
  [ -z "${INVOCATION_ID:-}" ] || die "FORGE_PERF_HOST_OPS=skip is refused under systemd"
  if [ -n "$(curl -fsS --connect-timeout 1 -m 2 -X PUT \
    "${FORGE_PERF_IMDS_URL:-http://169.254.169.254}/latest/api/token" \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 5' 2>/dev/null || true)" ]; then
    die "FORGE_PERF_HOST_OPS=skip is refused on an EC2 instance"
  fi
}
refuse_skip_on_box
