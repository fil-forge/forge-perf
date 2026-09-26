# Runner

The scripts under `scripts/host/` run on the box as root, started by the `forge-perf-*` systemd units. They also run on a laptop in skip mode, which exercises them against Docker Desktop without touching the host.

## The box

| Script | Runs | Does |
|---|---|---|
| `provision.sh` | once from cloud-init, then between runs when `host/` changes | installs the pins in `host/versions.env`, disables unattended upgrades and the timers listed in the script, holds the kernel and snaps, loads `sch_netem`, `sch_prio` and `cls_u32`, installs Docker's configuration and the NVMe unit |
| `install-tools.sh` | from `provision.sh` | Go, ucantool and AWS CLI v2, each checked against its pinned SHA-256 |
| `nvme.sh boot` | `forge-perf-nvme.service`, every boot, before Docker | formats the instance store, mounts it at `/mnt/forge-perf/nvme` and binds it over `/var/lib/docker/volumes` |
| `box-facts.sh` | each run | prints the machine and software facts the run record carries, as JSON |

`provision.sh` prints `=== provisioned: N change(s) ===` last. A second run with no new pins or files prints 0 and restarts nothing. On first boot, installing Docker CE starts the daemon before its configuration exists, so the script stops `docker.socket` and `docker.service`, installs `daemon.json`, the `docker.service` drop-in and the NVMe unit, reloads systemd, then starts the NVMe unit and Docker in that order. The drop-in makes Docker require the NVMe unit: if the format fails, Docker stays down and no run starts.

`nvme.sh boot` formats on every boot, so a reboot, a stop/start and a resize all start from a blank drive. The one exception is a reboot during a run: when `/var/lib/forge-perf/state/current.json` exists and the device already carries the `forge-perf-nvme` label, it mounts the device as it is so recovery can collect what the run left. The format time is logged to the unit's journal.

### Provisioning on a laptop

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

## Wipe and recovery

| Script | Runs | Does |
|---|---|---|
| `wipe.sh` | last step of every run; `ExecStopPost=wipe.sh --if-dirty` of the run unit; from `recover.sh` | returns the box to the state a run starts from |
| `recover.sh` | `forge-perf-recover.service`, every boot, before the poll timers and the run unit | closes out a run that a reboot interrupted, then flushes the outbox |
| `outbox.sh flush` | from `recover.sh`, and between runs | uploads raw tarballs, then records |

### The wipe

`wipe.sh`, in order:

1. `make nuke YES=1` in the smelt checkout under the work tree. A missing or broken checkout skips this step; the next ones do the same job.
2. Remove every remaining container, every volume by name, and `forge-network`. `docker volume prune` would touch only anonymous volumes.
3. Empty piri's six buckets, `$FORGE_PERF_PIRI_BUCKET_PREFIX` followed by `allocations`, `acceptances`, `claims`, `receipts`, `pdp` and `consolidation`, and abort their incomplete multipart uploads.
4. Delete the work tree (`/mnt/forge-perf/nvme/work`), then fail if any container or volume remains.
5. `fstrim` the NVMe mount and drop the page cache.
6. Remove every image whose digest is in neither `config/images.lock` nor the run's pinned set, `/var/lib/forge-perf/state/images.pinned`.
7. Delete `/run/forge-perf/secrets` and `/run/forge-perf/aws`.

The wipe never stops Docker, so it runs inside a unit ordered after `docker.service`. The NVMe is formatted only at boot, by `nvme.sh`. Every step is safe to repeat, and a second wipe changes nothing. `--if-dirty` returns at once when no container, volume, `forge-network`, work tree or secret is left; it does not look at the buckets.

The wipe takes `/run/forge-perf/run.lock` on descriptor 9 and waits for it. A caller that already holds the lock exports `FORGE_PERF_LOCK_HELD=1`, as `run.sh` and `recover.sh` do.

### Recovery at boot

`recover.sh` reads `/var/lib/forge-perf/state/current.json`:

| Field | Meaning |
|---|---|
| `run_id` | the run in progress |
| `phase` | one of `preflight`, `boot`, `drill`, `recorded`, `uploaded`, `wiping` |
| `run_dir` | the run's directory; default `/mnt/forge-perf/nvme/work/run`, which holds `runner.json` |

With no `current.json` it only flushes the outbox. Otherwise, in order, it stops every container Docker restarted at daemon start. For a phase before `recorded`, or a phase it does not know, it then collects each container's `docker logs --timestamps` and the run directory into `/var/lib/forge-perf/outbox/<run_id>.raw.tar.zst` and writes a `no_data` record with reason `drill_interrupted` to `<run_id>.json` beside it, with `record.py build` from the run's `runner.json`. It then removes the containers, empties the buckets and wipes (all through `wipe.sh`), removes `current.json` and flushes the outbox. From `recorded` on, the run's own files are already in the outbox, so recovery adds none.

The tarball leaves out every `*.env` file and `provider/`, and drops every line that names `access_key_id` or `secret_access_key`, which `piri init` prints. When piri's credentials file is still readable and either value appears in the collected files, recovery writes no tarball and the record carries `raw_missing`. The denylist the record builder checks comes from `FORGE_PERF_DENYLIST_FILE`, or from SSM `/forge-perf/denylist` into `/run/forge-perf/secrets/denylist.regex`. Each step skips what an earlier attempt finished, so a failed recovery can be restarted with `systemctl restart forge-perf-recover`.

### The outbox

`outbox.sh flush` uploads `/var/lib/forge-perf/outbox/<run_id>.raw.tar.zst` to `s3://$FORGE_PERF_RESULTS_BUCKET/raw/<box>/<run_id>/raw.tar.zst` with `--checksum-algorithm SHA256`, then `<run_id>.json` to `published/<box>/<run_id>.json` with `--content-md5` and `--if-none-match '*'`. A record waits while its tarball is still in the outbox. A zero exit, or a 412 on a record, removes the file; the box never reads the bucket back. Anything left makes it exit 1, and the next flush tries again.

### piri's S3 store

`config/piri-s3.env` says where piri keeps its blobs and how the host reaches the same buckets. Each value is a default that `box.conf` or the environment overrides.

| Variable | Default | Meaning |
|---|---|---|
| `FORGE_PERF_PIRI_S3_ENDPOINT` | `s3.us-east-2.amazonaws.com` | `host:port` piri dials, as smelt's manifest takes it |
| `FORGE_PERF_PIRI_S3_INSECURE` | `false` | `true` for plain HTTP |
| `FORGE_PERF_PIRI_S3_REGION` | `us-east-2` | |
| `FORGE_PERF_PIRI_S3_HOST_URL` | empty: `http(s)://<endpoint>` | the URL the host uses when it reaches the store at another address than piri |
| `FORGE_PERF_PIRI_S3_CA_BUNDLE` | empty: the system store | a PEM bundle the host trusts for the endpoint |
| `FORGE_PERF_PIRI_S3_HOST_AUTH` | `role` | `role`: the host's own credentials (the instance role on the box); `key`: the credentials file |
| `FORGE_PERF_PIRI_S3_CREDENTIALS` | `/run/forge-perf/secrets/piri-s3.env` | `FORGE_PERF_PIRI_S3_KEY_ID` and `FORGE_PERF_PIRI_S3_SECRET` |

## Local run

On a laptop, `FORGE_PERF_HOST_OPS=skip` turns every host-level operation into a logged no-op. The scripts reach the host only through the wrappers in `scripts/host/lib.sh` (`host_op`, `host_check`, `host_read`, `imds`, `instance_store_dev`), so the same code runs in both places. In the wipe, `fstrim` and `sysctl vm.drop_caches=3` log `host-op skipped: <command>` and succeed. `lib.sh` refuses skip mode under systemd and wherever instance metadata answers.

Skip mode also narrows what the wipe removes, since a laptop runs other things. It removes containers of compose project `smelt` (or `$COMPOSE_PROJECT_NAME`) and those named `smeltery-*` or `forge-perf-*`, volumes of that project or named `smelt_*`, and only those images outside the pinned set whose repository appears in `config/images.lock` or `images.pinned`. Everything else on the laptop stays. Without `flock` installed (macOS), the lock is skipped with a message.

A local MinIO stands in for AWS S3. piri reaches it from its container as `host.docker.internal:9000`, the laptop as `localhost:9000`. From the root of a forge-perf checkout (`local/` is ignored by git):

```sh
mkdir -p local/state local/nvme local/outbox local/run
docker run -d --name local-minio -p 9000:9000 \
  -e MINIO_ROOT_USER=local-key -e MINIO_ROOT_PASSWORD=local-secret-key \
  ghcr.io/fil-forge/minio:RELEASE.2025-10-15T17-29-55Z server /data

cat >local/box.conf <<EOF
FORGE_PERF_BOX_ID=local
FORGE_PERF_CHECKOUT=$PWD
FORGE_PERF_PIRI_BUCKET_PREFIX=local-piri-0-
FORGE_PERF_RESULTS_BUCKET=local-results
FORGE_PERF_PIRI_S3_ENDPOINT=host.docker.internal:9000
FORGE_PERF_PIRI_S3_INSECURE=true
FORGE_PERF_PIRI_S3_HOST_URL=http://localhost:9000
FORGE_PERF_PIRI_S3_HOST_AUTH=key
FORGE_PERF_PIRI_S3_CREDENTIALS=$PWD/local/piri-s3.env
EOF
printf '%s\n' FORGE_PERF_PIRI_S3_KEY_ID=local-key FORGE_PERF_PIRI_S3_SECRET=local-secret-key \
  >local/piri-s3.env

export FORGE_PERF_HOST_OPS=skip FORGE_PERF_BOX_CONF="$PWD/local/box.conf" \
  FORGE_PERF_STATE_DIR="$PWD/local/state" FORGE_PERF_NVME_MOUNT="$PWD/local/nvme" \
  FORGE_PERF_OUTBOX="$PWD/local/outbox" FORGE_PERF_RUNTIME="$PWD/local/run" \
  FORGE_PERF_DENYLIST_FILE=/path/to/denylist.regex
# The host's own calls (the outbox) go to the same MinIO.
export AWS_ENDPOINT_URL=http://localhost:9000 AWS_ACCESS_KEY_ID=local-key \
  AWS_SECRET_ACCESS_KEY=local-secret-key AWS_REGION=us-east-2

for s in allocations acceptances claims receipts pdp consolidation; do
  aws s3 mb "s3://local-piri-0-$s"
done
aws s3 mb s3://local-results

scripts/host/wipe.sh               # removes the smelt stack, empties the buckets
scripts/host/wipe.sh --if-dirty    # prints "clean; nothing to do"
scripts/host/recover.sh            # with local/state/current.json, closes out that run
```

The credentials file sits outside `local/run/secrets`, which the wipe deletes. Skip mode leaves out what depends on the box itself: the instance-store format, `fstrim` and the page cache, the unit ordering after Docker, and AWS S3's network path.
