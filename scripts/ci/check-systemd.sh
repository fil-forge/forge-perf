#!/usr/bin/env bash
# Runs `systemd-analyze verify` over the unit files in systemd/ and the drop-in
# for docker.service in host/docker/.
#
# The units are checked from a scratch unit directory that also holds a stub
# docker.service, so the drop-in and the ordering between the NVMe unit and
# Docker are verified the way the box loads them. systemd-analyze exists only
# on Linux: elsewhere the check skips with a notice, and in CI a missing tool
# fails it.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
shopt -s nullglob
units=(systemd/*.service systemd/*.timer)
if [ "${#units[@]}" -eq 0 ]; then
  echo "systemd: no units"
  exit 0
fi
if ! command -v systemd-analyze >/dev/null; then
  if [ "${CI:-}" = true ]; then
    echo "systemd: systemd-analyze is missing" >&2
    exit 1
  fi
  echo "systemd: skipped, no systemd-analyze on this machine"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "${units[@]}" "$work/"
printf '[Unit]\nDescription=stub\n[Service]\nExecStart=/bin/true\n' >"$work/docker.service"
mkdir "$work/docker.service.d"
cp host/docker/forge-perf.conf "$work/docker.service.d/"

names=()
for u in "${units[@]}"; do names+=("$work/$(basename "$u")"); done
# Trailing colon: the scratch directory first, then the built-in search path.
out="$(SYSTEMD_UNIT_PATH="$work:" systemd-analyze verify "${names[@]}" "$work/docker.service" 2>&1)" || {
  echo "$out" >&2
  exit 1
}
# verify exits 0 on some warnings; a warning about our own files fails the check.
if grep -F "$work" <<<"$out" >&2; then
  exit 1
fi
echo "systemd: ${#units[@]} unit(s) and the docker drop-in verified"
