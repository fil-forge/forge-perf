#!/usr/bin/env bash
# Print the facts that describe this box and its software as one JSON object,
# for the run record: instance type and IDs from instance metadata, kernel, CPU
# model and features, memory, the instance-store device and model, the pinned
# tools' versions, the unpinned archive packages' versions,
# Docker's configuration, timers, clock state and the kernel settings the
# ingest path depends on. run.sh writes it into each run's directory, so the
# raw tarball carries it; only the subset in runner.json's `box` enters the
# record and the box fingerprint.
#
# Read-only. A fact the host cannot give (a laptop in local mode, a tool not
# installed) is null rather than an error, so the record says what is missing.
#
#   box-facts.sh [> box-facts.json]
# shellcheck disable=SC2016 # awk programs and Go templates, not shell
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

forge_perf_init

# q <command...>: its output, or nothing if it fails. The subshell keeps a die
# inside the command (instance_store_dev) from ending this script.
q() { ( "$@" ) 2>/dev/null || true; }

features="$(q host_read awk -F': ' '/^Features/ { print $2; exit }' /proc/cpuinfo)"
[ -n "$features" ] || features="$(q host_read awk -F': ' '/^flags/ { print $2; exit }' /proc/cpuinfo)"
has_sha2=null
if [ -n "$features" ]; then
  has_sha2=false
  grep -qwE 'sha2|sha_ni' <<<"$features" && has_sha2=true
fi

# lscpu's model name; on arm64 it can be "-", so MIDR_EL1 identifies the core.
# awk reads to the end: exiting at the match can end lscpu with SIGPIPE.
cpu_model="$(q host_read lscpu | awk -F': *' 'm == "" && /^Model name/ { m = $2 } END { if (m != "") print m }')"
case "$cpu_model" in
  '' | -) cpu_model="$(q host_read cat /sys/devices/system/cpu/cpu0/regs/identification/midr_el1)" ;;
esac

nvme_dev="$(q instance_store_dev)"
nvme_size="" nvme_model=""
if [ -n "$nvme_dev" ]; then
  nvme_size="$(q host_read lsblk -dnbo SIZE "$nvme_dev" | tr -d ' ')"
  nvme_model="$(q host_read lsblk -dno MODEL "$nvme_dev" | sed 's/ *$//')"
fi

# "name version" per line for the archive packages and the time daemons.
# shellcheck disable=SC2086 # a list of names
archive="$(for p in $ARCHIVE_PACKAGES chrony systemd-timesyncd; do
  v="$(q host_read dpkg-query -W -f='${Version}' "$p")"
  [ -z "$v" ] || printf '%s %s\n' "$p" "$v"
done)"

stamp() { q cat "$R/etc/forge-perf/$1.version" | awk '{ print $1 }'; }

jq -n \
  --arg box_id "$FORGE_PERF_BOX_ID" \
  --arg instance_type "$(q imds instance-type)" \
  --arg instance_id "$(q imds instance-id)" \
  --arg ami_id "$(q imds ami-id)" \
  --arg kernel "$(uname -r)" \
  --arg arch "$(uname -m)" \
  --arg cpu_model "$cpu_model" \
  --arg cpu_features "$features" \
  --argjson cpu_has_sha2 "$has_sha2" \
  --arg nproc "$(q nproc)" \
  --arg mem_total_kb "$(q host_read awk '/^MemTotal/ { print $2 }' /proc/meminfo)" \
  --arg nvme_device "$nvme_dev" \
  --arg nvme_size_bytes "$nvme_size" \
  --arg nvme_model "$nvme_model" \
  --arg docker "$(q docker version --format '{{.Server.Version}}')" \
  --arg containerd "$(q host_read dpkg-query -W -f='${Version}' containerd.io)" \
  --arg compose "$(q docker compose version --short)" \
  --arg daemon_json_sha256 "$(q host_read sha256sum /etc/docker/daemon.json | awk '{ print $1 }')" \
  --arg go "$(stamp go)" \
  --arg ucantool "$(stamp ucantool)" \
  --arg awscli "$(stamp aws)" \
  --arg fio "$(q fio --version)" \
  --arg archive "$archive" \
  --arg timers "$(q host_read systemctl list-timers --all --no-legend --plain | awk '{ print $(NF-1) }')" \
  --arg ntp_synchronized "$(q host_read timedatectl show -p NTPSynchronized --value)" \
  --arg thp "$(q host_read cat /sys/kernel/mm/transparent_hugepage/enabled)" \
  --arg dirty_ratio "$(q host_read sysctl -n vm.dirty_ratio)" \
  --arg dirty_background_ratio "$(q host_read sysctl -n vm.dirty_background_ratio)" \
  --arg tcp_congestion_control "$(q host_read sysctl -n net.ipv4.tcp_congestion_control)" \
  --arg forge_perf_sha "$(q git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)" \
  'def n: if . == "" then null else . end;
   def num: if . == "" then null else tonumber end;
   {box_id: $box_id,
    instance: {type: ($instance_type|n), id: ($instance_id|n), ami: ($ami_id|n)},
    kernel: $kernel, arch: $arch,
    cpu: {model: ($cpu_model|n), features: ($cpu_features|n), has_sha2: $cpu_has_sha2, nproc: ($nproc|num)},
    mem_total_kb: ($mem_total_kb|num),
    nvme: {device: ($nvme_device|n), model: ($nvme_model|n), size_bytes: ($nvme_size_bytes|num)},
    versions: {docker: ($docker|n), containerd: ($containerd|n), compose: ($compose|n),
               go: ($go|n), ucantool: ($ucantool|n), awscli: ($awscli|n), fio: ($fio|n)},
    archive_packages: ($archive | split("\n") | map(select(. != "") | split(" ") | {(.[0]): .[1]}) | add // {}),
    docker_daemon_json_sha256: ($daemon_json_sha256|n),
    timers: ($timers | split("\n") | map(select(. != ""))),
    clock: {ntp_synchronized: ($ntp_synchronized | if . == "" then null else . == "yes" end)},
    kernel_settings: {transparent_hugepage: ($thp|n), dirty_ratio: ($dirty_ratio|num),
                      dirty_background_ratio: ($dirty_background_ratio|num),
                      tcp_congestion_control: ($tcp_congestion_control|n)},
    forge_perf_sha: ($forge_perf_sha|n)}'
