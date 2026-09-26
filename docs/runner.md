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

`run.sh` writes a complete `runner.json` to `/var/lib/forge-perf/state/runner.json` on the root volume before it first writes `current.json`, and copies it into the run directory once preflight has created that. A stop/start or resize mid-run leaves the instance store blank, and recovery then reads that copy, so the interrupted run still gets a record.

The tarball leaves out every `*.env` file and `provider/`, and drops every line that names `access_key_id` or `secret_access_key`, which `piri init` prints. Recovery then checks the collected files for piri's key ID, piri's secret and the harness credential. It reads piri's pair from its credentials file while `/run` still holds it; after a reboot `/run` is empty, so it reads them from the SSM parameters `piri-s3-access-key-id` and `piri-s3-secret-access-key` under `FORGE_PERF_SSM_PATH` (default `/forge-perf`), and the harness credential from `harness-deploy-key` there when that parameter exists. When a value appears, or the values cannot be read, recovery writes no tarball and the record carries `raw_missing`. The record builder checks the record against the same strings. The denylist it also checks comes from `FORGE_PERF_DENYLIST_FILE`, or from the SSM parameter `denylist` under the same path into `/run/forge-perf/secrets/denylist.regex`.

Recovery always reaches the wipe, with or without a record. When `current.json` has no usable `run_id`, the run has no usable `runner.json`, or `record.py` writes nothing, recovery logs why, keeps any raw tarball in the outbox, wipes, and moves `current.json` to `current.json.failed-<time>` so the next boot formats the NVMe. A failed SSM read stops recovery with `current.json` kept, since a retry can succeed: each step skips what an earlier attempt finished, so `systemctl restart forge-perf-recover` or the next boot picks up where it stopped. The unit restarts a failed attempt after a minute (`Restart=on-failure`). On the third attempt (`FORGE_PERF_RECOVER_ATTEMPTS`) recovery goes on without the missing input and wipes. A failed wipe also keeps `current.json` until the third attempt, which moves it aside and exits 4. The unit does not restart on that status (`RestartPreventExitStatus=4`). It also leaves `/run/forge-perf/recover-failed`, and while that file exists every later start of the unit exits 4 at once, so a poll or run that requires the unit fails too and the heartbeat goes stale. A reboot clears `/run`, and the next boot formats the NVMe. After a manual `wipe.sh`, removing the file lets recovery run again. A collection step that fails, such as `zstd` on a full disk, costs only the tarball: recovery removes the partial files, writes the record with `raw_missing` and wipes. A failing `docker stop` is logged, and the wipe removes the containers. The poll and run units must declare `Requires=` as well as `After=` on `forge-perf-recover.service`, so no run starts on a box recovery has not closed out.

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

## A run

`run.sh` runs the stack once against one set and stops after drill setup. Every run takes `/run/forge-perf/run.lock` with `flock -n`; a second instance exits 0 at once.

```
run.sh [--set FILE] [--series SERIES] [--workers N] [--size SIZE] [--duration DURATION] [--until STEP]
```

Without `--set` it takes the run the poller left in `/var/lib/forge-perf/state/pending.json` (`{kind, set, superseded, pairing_id}`, plus `workers`, `size` and `duration` for a campaign) and removes that file. With `--set` it runs the file as a manual run in `--series`, default `calibration`. While `config/launch.conf` has `SERIES_LIVE=0`, every run is series `calibration`. `--until` stops after the named step and leaves the stack running; `scripts/host/wipe.sh` removes it.

A set is the JSON the poller resolves:

```json
{"smelt": "<40-hex>",
 "harness": {"sha": "<40-hex>", "pinned": true, "main": "<40-hex or null>"},
 "images": {"ghcr.io/fil-forge/ingot:main": "sha256:<64-hex>", "…": "…"},
 "resolved_at": "2026-09-26T03:00:04Z"}
```

It needs a digest for every line of `config/images.tracked`. A set without `smelt` takes `SMELT_REF` from `config/smelt.conf`, and one without `harness.sha` takes `SQ_PIN` from `config/harness.conf`. [`calibration/sets/shakedown.json`](../calibration/sets/shakedown.json) is one such file.

### Before the first step

`run.sh` refuses to start, with exit status 2 and no record, when there is no `config/settings/<instance type>.env` for the type instance metadata reports, when `WORKERS` is empty there and no `--workers` is given, or when the set or a drill setting cannot be read. A run taken from `pending.json` that refuses to start moves the file to `pending.json.rejected`, so the next poll does not start it again. Otherwise it writes `runner.json` (fields in [record.md](record.md#what-the-builder-reads)) to the state directory, then `current.json` with phase `preflight`, and replaces `last-started.json` with the set. The run ID is `<box>-<yyyymmdd>t<hhmmss>z` of the moment the run starts.

### Steps

Each step runs its slow commands under `timeout` with the budget below, and every other `docker` and `aws` call gets a minute (`FORGE_PERF_CALL_TIMEOUT`); an overrun stops the run with reason `step_timeout`. Any other failure stops it with the reason in the table, which `runner.json` records. A failure the table does not name is `runner_error`.

| Step | What it does | Budget | Reasons |
|---|---|---|---|
| preflight | clock synchronized (`timedatectl show -p NTPSynchronized --value` prints `yes`); CPU with `sha2`; `modprobe sch_netem`; Docker 25 or newer; every box fact the record schema requires was read (instance metadata, Docker and Compose versions, cores, memory, the instance-store model, size and filesystem); `git status --porcelain` of the forge-perf checkout empty; no container, volume, `forge-network` or object in piri's six buckets, or else one wipe and a second look; piri's S3 key from SSM to `/run/forge-perf/secrets/piri-s3.env` | wipe 30 min | `preflight_failed`, `instrument_modified`, `dirty_start` (the run goes on), `s3_unreachable`, `secrets_unavailable` |
| checkout | fetch both mirrors; require both SHAs with `git cat-file -e <sha>^{commit}`; check out smelt and the harness in the work tree; check that smelt has the settings a run needs; build the drill (`GOWORK=off go build -o bin/drill ./cmd/drill`, after `go mod download`) | fetch 10 min each, modules 15 min, build 15 min | `mirror_fetch_failed`, `smelt_unreachable`, `harness_unreachable`, `go_module_fetch_failed`, `harness_build_failed` |
| images | render `config/smelt-manifest.yml.tmpl`; `make generate`; `docker compose config --images` must list only pinned references; piri-0 must get `FORGE_PERF_PIRI_S3_ENDPOINT` and `FORGE_PERF_PIRI_BUCKET_PREFIX`, with no `piri-minio` service, since a smelt that predates the manifest's `storage.s3` ignores it; pull each pinned image that `docker image inspect` does not find, four at a time; map each image to its compose services in `compose-images.json`, which holds only each service's image and piri's S3 target, since the interpolated model carries piri's key | generate 10 min, pull 20 min | `image_pull_failed`, `runner_error` |
| boot | `current.json` phase `boot`; `docker network create --subnet $NET_SUBNET forge-network` (`config/latency.env`); `make up`, which waits up to 600 s for health | 15 min | `stack_boot_failed` |
| setup | `perf-drill.sh setup` with `INGOT_URL=http://<ingot's forge-network address>:80`, which mints the drill's key and stores and reads back 4 MiB through ingot | 10 min | `setup_failed` |

`netem.sh apply` and each `netem.sh verify` pass that follow get 5 minutes each.

At exit `run.sh` removes `current.json` and prints the run's reasons. Exit status 0 means the run reached its last step, and 1 that a step stopped it.

### What a run reads

| File | Holds |
|---|---|
| `config/images.tracked` | the smelt variable and `repo:tag` of each image under test; the set supplies the digest |
| `config/images.lock` | the smelt variable, `repo:tag` and index digest of each third-party image, and the netem sidecar |
| `config/harness.conf` | `SQ_REPO`; `SQ_PIN`, the harness commit while harness main cannot run the capped drill; `SQ_AUTH`, the harness credential |
| `config/smelt.conf` | `SMELT_REPO`; `SMELT_REF`, smelt's `perf/shakedown` head until the smelt changes reach main; `MANIFEST_NAME` |
| `config/smelt-manifest.yml.tmpl` | one piri node on Postgres with its blobs in S3; `@ENDPOINT@`, `@BUCKET_PREFIX@` and `@INSECURE@` come from `config/piri-s3.env` and `box.conf` |
| `config/settings/<instance type>.env` | `BOX_TIER`, `BASELINE_BYTES_PER_S`, the size and duration per kind of run, and one smelt variable per drill flag; `WORKERS` stays empty until calibration freezes it |
| `config/launch.conf` | `SERIES_LIVE` |

Every image variable is exported as `<repo>@sha256:<digest>`, so each compose call of the run, smelt's scripts included, sees the same images. `run.sh` also exports `PIRI_INDEXER=off`, empty `SPRUE_INDEXER_ENDPOINT` and `SPRUE_INDEXER_DID`, `SMELT_WORKSPACE=0`, `SMELT_MANIFEST`, piri's key as `SMELT_PIRI_S3_ACCESS_KEY_ID` and `SMELT_PIRI_S3_SECRET_ACCESS_KEY`, and `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` under `/run/forge-perf/aws`, where `s3-key.sh` writes the drill's key. `AWS_REGION` is the box's region (`FORGE_PERF_REGION`, default `us-east-2`) for the host's own calls; smelt's scripts run without it and without any `AWS_ENDPOINT_URL` or `AWS_ACCESS_KEY_ID`, since the drill's profile carries ingot's own. On the box Go uses `GOCACHE` and `GOMODCACHE` under `/var/cache/forge-perf/go` with `GOTOOLCHAIN=local`.

`box.conf` supplies `FORGE_PERF_BOX_ID`, `FORGE_PERF_PIRI_BUCKET_PREFIX` (the six buckets' shared prefix, ending in `piri-0-`), `FORGE_PERF_SMELT_BUCKET_PREFIX` (the manifest's prefix; default: the piri prefix without `piri-0-`), `FORGE_PERF_SSM_PATH` (default `/forge-perf`) and `FORGE_PERF_REGION`.

### Mirrors and the harness credential

`/var/lib/forge-perf/mirror/{smelt,storage-qualification}.git` are bare mirrors on the root volume. Each fetch takes `+refs/heads/*:refs/heads/*` and `+refs/pull/*/head:refs/pull/*/head`, so a commit stays reachable after its branch is deleted on merge: the pinned harness commit is the head of an open pull request. A failed fetch stops the run only when the commit is not already in the mirror.

smelt is public. The harness credential is `SQ_AUTH` in `config/harness.conf`; `FORGE_PERF_HARNESS_AUTH` overrides it for a local run:

| Value | Credential |
|---|---|
| `deploy-key` | a read-only deploy key in SSM `<path>/harness-deploy-key`, used over SSH with GitHub's host keys pinned in `config/github-known-hosts` |
| `app` | a GitHub App with read access to the harness repository's contents. SSM `<path>/harness-app` holds `{"app_id", "installation_id", "private_key"}`, and `harness-token.sh` mints an installation token for each run, scoped to that one repository and `contents: read` |
| `none` | the caller's own git credentials, for a local run |

The deploy key works only where the fil-one organization allows deploy keys; the App gives the same read-only access where it does not. Either credential lives under `/run/forge-perf/secrets` for the run and goes with the wipe.

## Local run

On a laptop, `FORGE_PERF_HOST_OPS=skip` turns every host-level operation into a logged no-op. The scripts reach the host only through the wrappers in `scripts/host/lib.sh` (`host_op`, `host_check`, `host_read`, `imds`, `instance_store_dev`), so the same code runs in both places. In the wipe, `fstrim` and `sysctl vm.drop_caches=3` log `host-op skipped: <command>` and succeed. `lib.sh` refuses skip mode under systemd and wherever instance metadata answers.

Skip mode also narrows what the wipe removes, since a laptop runs other things. It removes containers of compose project `smelt` (or `$COMPOSE_PROJECT_NAME`) and those named `smeltery-*` or `forge-perf-*`, volumes of that project or named `smelt_*`, and only those images outside the pinned set whose repository is a pinned `ghcr.io/fil-forge/` one. Third-party images such as `postgres` stay, since other projects on a laptop share them. Everything else on the laptop stays. Without `flock` installed (macOS), the lock is skipped with a message.

A local MinIO stands in for AWS S3. piri reaches it from its container as `host.docker.internal:9000`, the laptop as `localhost:9000`. It keeps its objects in `local/minio-data` on the laptop's disk. The MinIO image declares `/data` a volume, so without the bind mount every container leaves an anonymous volume on Docker's disk, where ingot's spool also grows during a drill. From the root of a forge-perf checkout (`local/` is ignored by git):

```sh
mkdir -p local/state local/nvme local/outbox local/run local/minio-data
docker run -d --name local-minio -p 9000:9000 -v "$PWD/local/minio-data:/data" \
  -e MINIO_ROOT_USER=local-key -e MINIO_ROOT_PASSWORD=local-secret-key \
  ghcr.io/fil-forge/minio:RELEASE.2025-10-15T17-29-55Z server /data
until curl -fs http://localhost:9000/minio/health/ready; do sleep 1; done

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

A run against Docker Desktop needs five more settings in `local/box.conf`, and `ucantool` on `PATH` (without it smelt's `init.sh` runs `go install ucantool@latest`):

```sh
cat >>local/box.conf <<EOF
FORGE_PERF_SECRETS=file                 # piri's key from the FORGE_PERF_PIRI_S3_CREDENTIALS file
FORGE_PERF_HARNESS_AUTH=none            # your own git credentials for storage-qualification
FORGE_PERF_CLIENT_PATH=published        # Docker Desktop does not route to container addresses
FORGE_PERF_GO_CACHE=                    # your own Go caches and toolchain
FORGE_PERF_MIRRORS=$PWD/local/mirror
EOF
GOBIN="$PWD/local/bin" go install github.com/fil-forge/ucantool@v0.1.0
PATH="$PWD/local/bin:$PATH" scripts/host/run.sh --set calibration/sets/shakedown.json --until setup
```

Instance metadata reports the type as `local` in skip mode, which selects `config/settings/local.env` (4 workers, 2 GB per run). The host checks (clock, CPU, `sch_netem`) log `host-check skipped` and pass. A checkout with uncommitted changes stops preflight as on the box; `FORGE_PERF_ALLOW_MODIFIED=1` lets it through in skip mode only. `FORGE_PERF_CLIENT_PATH=published` sends the drill to ingot's published port through Docker's proxy, so a local run measures that path too. smelt's stack uses compose project `smelt`, `forge-network` and host ports 15000 to 15141, so it cannot run beside another smelt stack.

To remove the local setup, wipe first, then remove MinIO with its data and the local state:

```sh
scripts/host/wipe.sh
docker rm -f local-minio
rm -rf local
```

The credentials file sits outside `local/run/secrets`, which the wipe deletes. Skip mode leaves out what depends on the box itself: the instance-store format, `fstrim` and the page cache, the unit ordering after Docker, and AWS S3's network path.
