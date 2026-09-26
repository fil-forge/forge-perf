# Runner

The scripts under `scripts/host/` run on the box as root, started by cloud-init and by the `forge-perf-*` systemd units. They also run on a laptop in skip mode, which exercises them without touching the host.

## The box

| Script | Runs | Does |
|---|---|---|
| `provision.sh` | once from cloud-init, then between runs when `host/` changes | installs the pins in `host/versions.env`, disables unattended upgrades and the timers listed in the script, holds the kernel and snaps, loads `sch_netem`, `sch_prio` and `cls_u32`, installs Docker's configuration and the NVMe unit |
| `install-tools.sh` | from `provision.sh` | Go, ucantool and AWS CLI v2, each checked against its pinned SHA-256 |
| `nvme.sh boot` | `forge-perf-nvme.service`, every boot, before Docker | formats the instance store, mounts it at `/mnt/forge-perf/nvme` and binds it over `/var/lib/docker/volumes` |
| `box-facts.sh` | each run | prints the machine and software facts the run record carries, as JSON |

`provision.sh` prints `=== provisioned: N change(s) ===` last. A second run with no new pins or files prints 0 and restarts nothing. On first boot, installing Docker CE starts the daemon before its configuration exists, so the script stops `docker.socket` and `docker.service`, installs `daemon.json`, the `docker.service` drop-in and the NVMe unit, reloads systemd, then starts the NVMe unit and Docker in that order. The drop-in makes Docker require the NVMe unit: if the format fails, Docker stays down and no run starts.

`nvme.sh boot` formats on every boot, so a reboot, a stop/start and a resize all start from a blank drive. The one exception is a reboot during a run: when `/var/lib/forge-perf/state/current.json` exists and the device already carries the `forge-perf-nvme` label, it mounts the device as it is so recovery can collect what the run left. The format time is logged to the unit's journal.

## Local run

On a laptop, `FORGE_PERF_HOST_OPS=skip` turns every host-level operation into a logged no-op. The scripts reach the host only through the wrappers in `scripts/host/lib.sh`, so the same code runs in both places.

| Wrapper | Used for | With `skip` |
|---|---|---|
| `host_op` | apt, `systemctl`, `mkfs`, `mount`, `sysctl` (including `vm.drop_caches`), `modprobe`, `snap`, files under `/etc` | logs `host-op skipped: <command>` to stderr and succeeds |
| `host_check` | questions such as "is Docker running" | logs and answers no |
| `host_read` | `lsblk`, `blkid`, `dpkg-query`, `sysctl -n`, `/proc` | logs and prints nothing |
| `imds` | instance type, instance ID, AMI ID | prints `local` |
| `instance_store_dev` | finding the NVMe | prints `/dev/forge-perf-local-nvme` |

`install-tools.sh` downloads and installs nothing, and `box-facts.sh` reports what the laptop has, with the rest as null. `lib.sh` refuses skip mode under systemd and wherever instance metadata answers, so it cannot reach the box through `box.conf`.

From the root of a forge-perf checkout (`local/` is ignored by git):

```sh
mkdir -p local
printf '%s\n' FORGE_PERF_BOX_ID=local "FORGE_PERF_CHECKOUT=$PWD" FORGE_PERF_MODE=local >local/box.conf
export FORGE_PERF_HOST_OPS=skip FORGE_PERF_BOX_CONF="$PWD/local/box.conf"

scripts/host/provision.sh          # lists every operation it would perform
scripts/host/nvme.sh boot          # the format and mounts, logged
scripts/host/box-facts.sh | jq .   # the laptop's facts, instance fields "local"
```

Skip mode leaves out everything that depends on the box itself: the instance-store format and its timing, the kernel modules for latency simulation, Docker's daemon configuration and AWS S3's network path. A scratch box covers those. `scripts/operator/scratch-box.sh up` launches one from the pinned AMI and runs `provision.sh` on it; it powers itself off `--hours` after launch (default 4), also across reboots, and `scratch-box.sh down` terminates it sooner. Its instance profile and security group are described in [operations.md](operations.md#the-scratch-boxs-instance-profile).
