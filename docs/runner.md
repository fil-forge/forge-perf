# Runner

The scripts under `scripts/host/` run on the box as root, started by the `forge-perf-*` systemd units. They also run on a laptop in skip mode, which exercises them against Docker Desktop without touching the host.

## The box

| Script | Runs | Does |
|---|---|---|
| `provision.sh` | once from cloud-init, then between runs when `host/` changes | installs the pins in `host/versions.env`, disables unattended upgrades and the timers listed in the script, holds the kernel and snaps, loads `sch_netem`, `sch_prio` and `cls_u32`, installs Docker's configuration and the NVMe unit |
| `install-tools.sh` | from `provision.sh` | Go, ucantool and AWS CLI v2, each checked against its pinned SHA-256 |
| `nvme.sh boot` | `forge-perf-nvme.service`, every boot, before Docker | formats the instance store, mounts it at `/mnt/forge-perf/nvme` and binds it over `/var/lib/docker/volumes` |
| `box-facts.sh` | each run, into the raw tarball as `box-facts.json` | prints the machine and software facts (Docker's configuration, timers, clock, kernel settings, package versions) as JSON; the record and its box fingerprint carry the subset `run.sh` puts in `runner.json` |

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
| `collect.sh` | from `run.sh` and `recover.sh` | builds a run's raw tarball |
| `outbox.sh flush` | from `run.sh`, `recover.sh`, and from `poll.sh` between runs | uploads raw tarballs, then records |

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

`collect.sh` builds the tarball from the run directory, smelt's `generated/perf-runs/` and each container's logs. It leaves out every `*.env` file and `provider/`, drops every line that names `access_key_id` or `secret_access_key`, which `piri init` prints, and then checks the collected files for piri's key ID, piri's secret and the harness credential. It reads piri's pair from its credentials file while `/run` still holds it; after a reboot `/run` is empty, so it reads them from the SSM parameters `piri-s3-access-key-id` and `piri-s3-secret-access-key` under `FORGE_PERF_SSM_PATH` (default `/forge-perf`), and the harness credential from `harness-deploy-key` there, and the GitHub App's private key from `harness-app`, when those parameters exist. The App's installation token is checked while `/run` still holds it. When a value appears, or the values cannot be read, recovery writes no tarball and the record carries `raw_missing`. The record builder checks the record against the same strings. The denylist it also checks comes from `FORGE_PERF_DENYLIST_FILE`, or from the SSM parameter `denylist` under the same path into `/run/forge-perf/secrets/denylist.regex`.

Recovery always reaches the wipe, with or without a record. When `current.json` has no usable `run_id`, the run has no usable `runner.json`, or `record.py` writes nothing, recovery logs why, keeps any raw tarball in the outbox, wipes, and moves `current.json` to `current.json.failed-<time>` so the next boot formats the NVMe. A failed SSM read stops recovery with `current.json` kept, since a retry can succeed: each step skips what an earlier attempt finished, so `systemctl restart forge-perf-recover` or the next boot picks up where it stopped. The unit restarts a failed attempt after a minute (`Restart=on-failure`). On the third attempt (`FORGE_PERF_RECOVER_ATTEMPTS`) recovery goes on without the missing input and wipes. A failed wipe also keeps `current.json` until the third attempt, which moves it aside and exits 4. The unit does not restart on that status (`RestartPreventExitStatus=4`). It also leaves `/run/forge-perf/recover-failed`, and while that file exists every later start of the unit exits 4 at once, so a poll or run that requires the unit fails too and the heartbeat goes stale. A reboot clears `/run`, and the next boot formats the NVMe. After a manual `wipe.sh`, removing the file lets recovery run again. A collection step that fails, such as `zstd` on a full disk, costs only the tarball: recovery removes the partial files, writes the record with `raw_missing` and wipes. A failing `docker stop` is logged, and the wipe removes the containers. The poll and run units must declare `Requires=` as well as `After=` on `forge-perf-recover.service`, so no run starts on a box recovery has not closed out.

### The outbox

`outbox.sh flush` uploads `/var/lib/forge-perf/outbox/<run_id>.raw.tar.zst` to `s3://$FORGE_PERF_RESULTS_BUCKET/raw/<box>/<run_id>/raw.tar.zst` with `aws s3 cp --checksum-algorithm SHA256`, which goes multipart past 5 GiB, then `<run_id>.json` to `published/<box>/<run_id>.json` with `aws s3api put-object --content-md5 --if-none-match '*'`. Each upload gets 15 minutes. A record waits while its tarball is still in the outbox. A zero exit, or a 412 on a record, removes the file; the box never reads the bucket back. Anything left makes it exit 1, and the next flush tries again.

The outbox holds at most 20 GB (`FORGE_PERF_OUTBOX_CAP_BYTES`). Past that, each flush drops the oldest raw tarballs until it fits; it never drops a record. A raw tarball whose upload still fails 24 hours after it was written is dropped too. Either way its record gains the flag `raw_missing`, in the schema's order of flags, and is uploaded without the tarball.

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

## Polling

`forge-perf-poll.timer` runs `poll.sh` two minutes after boot and then every five minutes; `forge-perf-nightly.timer` runs `poll.sh --nightly` at 03:00 UTC, and once at the next boot for a night the box was off. Both units have `Requires=` and `After=` on `forge-perf-recover.service`. A pass holds `/run/forge-perf/poll.lock`: a timer pass that finds the previous one still going exits, and the nightly pass waits up to 200 seconds for it. Each network call gets 60 seconds, and the poll unit's `TimeoutStartSec` is 240.

### The set

A pass resolves the set a run would test:

| Input | Resolved by |
|---|---|
| each image in `config/images.tracked` | an anonymous GHCR token, then `HEAD /v2/<repo>/manifests/<tag>`; the `Docker-Content-Digest` header is the multi-platform index digest |
| smelt | `SMELT_REF` from `config/smelt.conf` while it is set; otherwise `git ls-remote` of smelt's `refs/heads/main` |
| the harness | `SQ_PIN` from `config/harness.conf` while it is set, with `pinned: true` and `main: null`; otherwise `git ls-remote` of `refs/heads/main` with the harness credential, which the pass reads into its own directory under `/run/forge-perf` and deletes after the call |

The trigger key is `{smelt, harness.sha, images}` in canonical form. Third-party pins, forge-perf's own commit and the box facts are recorded per run and are outside the key, so they never start a run. A failed resolution writes nothing pending, adds one to `state/poll-failures`, and makes the pass exit 1; the next successful pass resets the count.

### State files

`/var/lib/forge-perf/state/` is on the root volume. Every file below is replaced through a synced temporary file.

| File | Written by | Holds |
|---|---|---|
| `pending.json` | `poll.sh` under `poll.lock`; taken by `run.sh` under the same lock | `{kind, set, first_seen_at, superseded}`, plus `attempt` and `not_before` (Unix seconds) for a retry |
| `last-started.json` | `run.sh` as a run starts, a manual `--set` run included | the set of that run, whatever its outcome; after a manual run on another set, the next pass makes main's set pending again, since it was not the last to run on the box |
| `current.json` | `run.sh` | the run in progress and its phase ([A run](#record-upload-and-wipe)) |
| `last-run.json` | `run.sh` as a run it took from `pending.json` ends; a manual run leaves it and `pending.json` alone | `{run_id, kind, set, superseded, attempt, previous_started, reasons}` |
| `pending.json.rejected` | `run.sh` | a pending run that could not start |
| `hold` | `status.sh hold` | `{at}`; the box starts no run while it exists |
| `poll-failures` | `poll.sh` | failed resolutions in a row |

### The decision

Latest wins, and at most one run is pending. With the set resolved, a pass writes `pending.json` by the first row that matches:

| Case | `pending.json` |
|---|---|
| a campaign's run is pending (`kind: campaign`) | unchanged: the campaign's run is its own, and the newest set is pending once the campaign ends |
| `--nightly` | `kind: nightly` with the new set, whatever changed; a pending trigger becomes the nightly, and its `superseded` grows by one when the set differs |
| the set's key equals `last-started.json`'s | unchanged: the set already ran, or is running now |
| the set's key equals the pending set's or `pending.json.rejected`'s | unchanged |
| a run is pending with another set | the new set replaces it, `superseded` grows by one, `kind` stays (a pending nightly stays nightly), and a retry's `attempt` and `not_before` go |
| nothing is pending | `{kind: trigger, set, superseded: 0}` |

`superseded` counts the sets a run covers beyond its own, and the record carries it. A set that ended `failed`, or `no_data` for a Forge-side reason, stays in `last-started.json`, so the key matches and the set waits for the nightly run. A nightly pass whose resolution fails still makes a nightly run pending, on the pending set or else the last one started.

**Infrastructure retries.** Before resolving, a pass between runs reads `last-run.json`. When its reasons include `image_pull_failed`, `secrets_unavailable`, `s3_unreachable`, `mirror_fetch_failed` or `go_module_fetch_failed` and its `attempt` is under 3, the pass puts `previous_started` back as `last-started.json` and makes the set pending again with `attempt + 1` and `not_before` 15 minutes on, keeping its kind. When a newer set is already pending, that set covers the failed one, and its `superseded` grows by one. After the third retry the set stays in `last-started.json` and waits for the nightly run. The pass then removes `last-run.json`; a campaign's run is never retried.

### Between runs

A run is going while `run.lock` is held or `forge-perf-run.service` is activating, active or deactivating (its `ExecStopPost` wipe runs after `run.sh` lets the lock go). During a run a pass only resolves, updates `pending.json` and writes the heartbeat. Between runs, in order:

1. **Held:** with `state/hold` present, the pass flushes the outbox and starts nothing, not even an update.
2. **Update:** when `git ls-remote origin` shows `FORGE_PERF_REF` (default `main`) ahead of the checkout's `HEAD`, the pass starts `update.sh` as the transient unit `forge-perf-update` and starts no run. `update.sh` resets the checkout, provisions, syncs the units, and as its last step writes `HEAD` to `state/updated-rev`. Until `updated-rev` matches `HEAD`, no run starts: a pass that finds `forge-perf-update` still going waits, and a pass that finds it stopped counts an update failure, exits 1 and starts `update.sh` again. The count adds to the heartbeat's `poll_failures`, so a provision that keeps failing raises the same alert as a set that cannot be resolved, and it clears once `updated-rev` matches. A campaign box (`FORGE_PERF_MODE=campaign`) and skip mode never update.
3. **Dispatch:** `systemctl start --no-block forge-perf-run.service` when a run is pending, its `not_before` has passed, and `WORKERS` is set in the instance type's settings file (or the pending run names its own). With no settings file for the instance type, the run waits and the pass says so. While a `forge-perf-outbox` flush is still uploading, the run waits for the next pass, so no upload shares the NIC with a drill; the run's own upload flushes whatever the outbox still holds. Starting an active oneshot is a no-op. `run.sh` takes `poll.lock` while it reads and removes `pending.json`, so no pass writes a set that the run then discards.
4. **Flush:** when nothing can start, `outbox.sh flush` as the transient unit `forge-perf-outbox`, if the outbox holds anything. Transient units (`RuntimeMaxSec` 45 minutes) keep a 15-minute upload or a provision clear of the poll unit's 240 seconds.

### Heartbeat

Every pass ends by writing `s3://$FORGE_PERF_RESULTS_BUCKET/published/<box>/heartbeat.json`:

```json
{"box": "main", "at": "2026-09-26T06:00:09Z", "forge_perf_sha": "<40-hex>", "state": "running",
 "run_id": "main-20260926t055512z", "run_started_at": "2026-09-26T05:55:12Z",
 "pending_kind": "trigger", "poll_failures": 0}
```

`state` is `running` during a run, else `held` while the hold exists, else `idle`. `run_id` and `run_started_at` are null outside a run, and `pending_kind` is null with nothing pending. `poll_failures` is the number of passes in a row that could not resolve the set, plus the number that found `update.sh` unfinished for the checkout's `HEAD` and not running. A heartbeat that does not go up makes the pass exit 1. The publish workflow alerts on the heartbeat's age, `poll_failures` and a long run ([DESIGN.md §7](DESIGN.md#7-results-and-the-page)).

### Holds and status

```
scripts/host/status.sh                      # the hold, the run, the state files, poll failures, the timers
scripts/host/status.sh hold [--wait-idle]   # no run starts; --wait-idle returns once no run is going
scripts/host/status.sh release
scripts/operator/hold.sh <box> on|off       # the same over SSM; `on` waits for idle, up to 7 hours
```

The hold is a file on the root volume, so it survives a reboot. It stops dispatch and updates; a run already going finishes, and pending sets keep coalescing, so the newest one starts after `release`. A pass reads the hold after it resolves the set, just before it would dispatch, and `run.sh` reads it again under `poll.lock` before it takes `pending.json`, leaving the file in place when the box is held. `hold --wait-idle` waits for `poll.lock` once before it checks for a run, so a pass that decided to start a run before the hold has either started it, which then counts as going, or finished.

## A run

`run.sh` runs the stack once against one set, measures it, records the result and wipes. Every run takes `/run/forge-perf/run.lock` with `flock -n`; a second instance exits 0 at once. `forge-perf-run.service` runs it on the box.

```
run.sh [--set FILE] [--series SERIES] [--workers N] [--size SIZE] [--duration DURATION] [--until STEP]
```

Without `--set` it takes the run the poller or `campaign.sh` left in `/var/lib/forge-perf/state/pending.json` (`{kind, set, superseded, attempt, pairing_id}`, plus `series`, `workers`, `size` and `duration` for a campaign) and removes that file, holding `poll.lock` while it does. A held box starts no pending run except a campaign's. When that run ends it writes `last-run.json` for the poller ([Polling](#the-decision)). With `--set` it runs the file as a manual run in `--series`, default `calibration`. While `config/launch.conf` has `SERIES_LIVE=0`, every run is series `calibration`. `--until` stops after the named step, one of preflight through check, and leaves the stack running with no record; `scripts/host/wipe.sh` removes it.

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
| preflight | clock synchronized (`timedatectl show -p NTPSynchronized --value` prints `yes`); CPU with `sha2`; `modprobe sch_netem`; Docker 25 or newer; every box fact the record schema requires was read (instance metadata, Docker and Compose versions, cores, memory, the instance-store model, size and filesystem); `git status --porcelain` of the forge-perf checkout empty; on a persistent box, `state/updated-rev`, when present, equal to the checkout's `HEAD`; no container, volume, `forge-network` or object in piri's six buckets, or else one wipe and a second look; piri's S3 key from SSM to `/run/forge-perf/secrets/piri-s3.env` | wipe 30 min | `preflight_failed`, `instrument_modified`, `dirty_start` (the run goes on), `s3_unreachable`, `secrets_unavailable` |
| checkout | fetch both mirrors; require both SHAs with `git cat-file -e <sha>^{commit}`; check out smelt and the harness in the work tree; check that smelt has the settings a run needs; build the drill (`GOWORK=off go build -o bin/drill ./cmd/drill`, after `go mod download`) | fetch 10 min each, modules 15 min, build 15 min | `mirror_fetch_failed`, `smelt_unreachable`, `harness_unreachable`, `go_module_fetch_failed`, `harness_build_failed` |
| images | render `config/smelt-manifest.yml.tmpl`; `make generate`; `docker compose config --images` must list only pinned references; piri-0 must get `FORGE_PERF_PIRI_S3_ENDPOINT` and `FORGE_PERF_PIRI_BUCKET_PREFIX`, with no `piri-minio` service, since a smelt that predates the manifest's `storage.s3` ignores it; pull each pinned image that `docker image inspect` does not find, four at a time; copy each image's `org.opencontainers.image.revision` and `org.opencontainers.image.source` labels into `runner.json`, null where a label is absent; map each image to its compose services in `compose-images.json`, which holds only each service's image and piri's S3 target, since the interpolated model carries piri's key | generate 10 min, pull 20 min | `image_pull_failed`, `runner_error` |
| boot | `current.json` phase `boot`; `docker network create --subnet $NET_SUBNET forge-network` (`config/latency.env`); `make up`, which waits up to 600 s for health | 15 min | `stack_boot_failed` |
| setup | `perf-drill.sh setup` with `INGOT_URL=http://<ingot's forge-network address>` (no `:80`: the drill's S3 client signs the port, and hilt's SigV4 check drops it), which mints the drill's key and stores and reads back 4 MiB through ingot; then, for a run with caps ([Campaigns](#campaigns)), `docker update --cpus` on each capped service, checked through `HostConfig.NanoCpus` | 10 min | `setup_failed`, `runner_error` (a cap not applied) |
| latency | `netem.sh apply`, then `netem.sh verify pre` (docs/DESIGN.md §5). A failed check (exit 1) does not stop the run: the drill runs, and the record is `invalid` from the check lines in `netem/latency.json` | 5 min each | `runner_error` (apply failed, or verify exited 2) |
| drill | `current.json` phase `drill`; `sync` and drop the page cache; `ethtool -S` of the primary interface; `perf-drill.sh run` under `timeout --signal=INT --kill-after=5m` of `DURATION` + 30 min, with one variable per drill flag from the settings file, `LABEL=<run_id>`, `CONFIG_NOTE=forge-perf/<run_id>` and `PERF_EXTRA_METADATA={"forge_perf": {"run_id", "series"}}`; meanwhile the interface's transmitted bytes every second and the NVMe's free space every 30 seconds; then `ethtool -S` again. `runner.json` gets `nic` (the five allowance counters' deltas, the median egress rate, and the seconds above `BASELINE_BYTES_PER_S`) and `watchdog_fired` when the `timeout` fired. The drill's own exit status goes to `metadata.json`, which the record reads | `DURATION` + 30 min | `disk_low` (under 2 GB free, the run goes on); `watchdog_timeout` in the record |
| check | `netem.sh verify post`, whose check lines the record reads (restarts, moved central addresses, missing qdiscs, round trips); `git status --porcelain` of the forge-perf checkout again | 5 min | `instrument_modified`, `step_timeout` (the run goes on) |

### Record, upload and wipe

Every run that started ends with these four steps, whether a step stopped it or not. They run without stopping at a failure, so a run always reaches the wipe.

| Step | What it does | Budget |
|---|---|---|
| collect | `collect.sh`: the run directory, smelt's `generated/perf-runs/` and each container's `docker logs --timestamps` into `/var/lib/forge-perf/outbox/<run_id>.raw.tar.zst`, with `*.env`, `provider/` and the lines `piri init` prints its key in left out. The tarball is not written while piri's key ID, piri's secret or the harness credential appears in the collected files, or when piri's key was never read; `runner.json` then gets `raw_missing` | 10 min |
| record | `time.run_finished_at`; `record.py build` into `/var/lib/forge-perf/outbox/<run_id>.json`, checked against the schema, the denylist (`FORGE_PERF_DENYLIST_FILE`, or SSM `<path>/denylist`, read at preflight) and the credentials; then `current.json` phase `recorded` | |
| upload | `outbox.sh flush`, raw before record; then phase `uploaded`. A failed upload leaves the files for the next flush | 15 min per file |
| wipe | phase `wiping`; `wipe.sh` with `FORGE_PERF_LOCK_HELD=1`; then `current.json` is removed | 30 min |

`current.json` is `{run_id, phase, run_dir}`, written through a temporary file that is synced before it replaces the old one. Its phase says what [recovery at boot](#recovery-at-boot) owes the run: before `recorded`, a `no_data` record; from `recorded` on, only the wipe. A failed wipe leaves `current.json` for the next boot's recovery.

Exit status 0 means the run was recorded and wiped, whatever its class, or reached `--until`; 1 that a step stopped it, or that the record or the wipe failed. `runner.json` names the reasons, and `run.sh` prints them with the class.

### Stopping a run

`forge-perf-run.service` is `Type=oneshot` with `TimeoutStartSec=6h`, `TimeoutStopSec=45min`, `KillMode=mixed`, `ExecStopPost=wipe.sh --if-dirty` and no `Restart=`. `systemctl stop`, or the start timeout, sends SIGTERM to `run.sh` alone. During the drill `run.sh` passes it on as SIGINT, so the drill writes its evidence and exits 2 (`timeout` kills it 5 minutes later if it has not), and the record carries `drill_interrupted`. At any other step the run ends at once with the same reason. Either way `run.sh` collects, records and wipes, and leaves the upload to the next flush, so the close-out fits in `TimeoutStopSec`; it exits 143. Whatever is left after that, or after the SIGKILL at `TimeoutStopSec`, `ExecStopPost` wipes. The unit has `Requires=` and `After=` on `forge-perf-recover.service`.

### What a run reads

| File | Holds |
|---|---|
| `config/images.tracked` | the smelt variable and `repo:tag` of each image under test; the set supplies the digest |
| `config/images.lock` | the smelt variable, `repo:tag` and index digest of each third-party image, and the netem sidecar |
| `config/harness.conf` | `SQ_REPO`; `SQ_PIN`, the harness commit while harness main cannot run the capped drill; `SQ_AUTH`, the harness credential |
| `config/smelt.conf` | `SMELT_REPO`; `SMELT_REF`, a smelt commit to hold runs at (empty: smelt main); `MANIFEST_NAME` |
| `config/smelt-manifest.yml.tmpl` | one piri node on Postgres with its blobs in S3; `@ENDPOINT@`, `@BUCKET_PREFIX@` and `@INSECURE@` come from `config/piri-s3.env` and `box.conf` |
| `config/settings/<instance type>.env` | `BOX_TIER`, `BASELINE_BYTES_PER_S`, the size and duration per kind of run, and one smelt variable per drill flag; `WORKERS` stays empty until calibration freezes it |
| `config/launch.conf` | `SERIES_LIVE` |

Every image variable is exported as `<repo>@sha256:<digest>`, so each compose call of the run, smelt's scripts included, sees the same images. `run.sh` also exports `PIRI_INDEXER=off`, empty `SPRUE_INDEXER_ENDPOINT` and `SPRUE_INDEXER_DID`, `SMELT_WORKSPACE=0`, `SMELT_MANIFEST`, piri's key as `SMELT_PIRI_S3_ACCESS_KEY_ID` and `SMELT_PIRI_S3_SECRET_ACCESS_KEY`, and `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` under `/run/forge-perf/aws`, where `s3-key.sh` writes the drill's key. `AWS_REGION` is the box's region (`FORGE_PERF_REGION`, default `us-east-2`) for the host's own calls; smelt's scripts run without it and without any `AWS_ENDPOINT_URL` or `AWS_ACCESS_KEY_ID`, since the drill's profile carries ingot's own. On the box Go uses `GOCACHE` and `GOMODCACHE` under `/var/cache/forge-perf/go` with `GOTOOLCHAIN=local`.

`box.conf` supplies `FORGE_PERF_BOX_ID`, `FORGE_PERF_PIRI_BUCKET_PREFIX` (the six buckets' shared prefix, ending in `piri-0-`), `FORGE_PERF_SMELT_BUCKET_PREFIX` (the manifest's prefix; default: the piri prefix without `piri-0-`), `FORGE_PERF_SSM_PATH` (default `/forge-perf`) and `FORGE_PERF_REGION`.

### Mirrors and the harness credential

`/var/lib/forge-perf/mirror/{smelt,storage-qualification}.git` are bare mirrors on the root volume. Each fetch takes every branch, `+refs/heads/*:refs/heads/*`, and one more namespace that keeps a pinned commit reachable after its branch is gone. The harness mirror adds `+refs/pull/*/head:refs/pull/*/head`, since the pinned harness commit is the head of an open pull request. The smelt mirror adds `+refs/tags/*:refs/tags/*` and no pull request heads: smelt is public, so anyone can open a pull request whose head would land on the root volume. forge-perf tags each smelt commit it pins as `forge-perf/<yyyymmdd>-<sha12>` in fil-forge/smelt, so the commit survives a rebuilt branch and `git gc`. A smelt mirror that still holds pull request heads from an earlier fetch drops them. A failed fetch stops the run only when the commit is not already in the mirror.

smelt is public. The harness credential is `SQ_AUTH` in `config/harness.conf`; `FORGE_PERF_HARNESS_AUTH` overrides it for a local run:

| Value | Credential |
|---|---|
| `deploy-key` | a read-only deploy key in SSM `<path>/harness-deploy-key`, used over SSH with GitHub's host keys pinned in `config/github-known-hosts` |
| `app` | a GitHub App with read access to the harness repository's contents. SSM `<path>/harness-app` holds `{"app_id", "installation_id", "private_key"}`, and `harness-token.sh` mints an installation token for each run, scoped to that one repository and `contents: read` |
| `none` | the caller's own git credentials, for a local run |

The default is `app`, set up as in [operations.md](operations.md#the-harness-credential-through-a-github-app). The deploy key works only where the organization allows deploy keys, and fil-one does not. Either credential lives under `/run/forge-perf/secrets` for the run and goes with the wipe.

## Campaigns

`campaign.sh` runs one set several times, each run through `forge-perf-run.service`, so every run keeps the unit's time limit, its record and its wipe.

```
campaign.sh                                    # a campaign box, from forge-perf-campaign.service
campaign.sh --set FILE --runs N [--workers W[,W...]] [--size SIZE] [--duration DURATION] [--pairing ID]
            [--cap SERVICE=CPUS[,SERVICE=CPUS...]]
```

For each run it writes `pending.json` with `kind: campaign`, the set, and the workers, size, duration and pairing ID it was given, under `poll.lock`, then runs `systemctl start --wait forge-perf-run.service`. It removes the run's `last-run.json` and any campaign `pending.json` left behind, so the poller neither retries a campaign's run nor finds one after the campaign. One workers value, or none, runs N times as series `campaign`; a comma list runs N rounds over it, reversed every other round, as series `calibration`. A pairing ID (`pair-<yyyymmdd>-<id>`) makes each record's trigger `pairing`. `SERIES_LIVE=0` still turns every series into `calibration`.

`--cap` is for the tier 1 falsification check ([DESIGN.md §9](DESIGN.md#9-calibration-and-ceilings)): a run with ingot and piri-0 held to one CPU each must land below the noise band.

```
campaign.sh --set calibration/sets/cal-1.json --runs 3 --cap ingot=1.0,piri-0=1.0
```

Each `SERVICE` is a compose service that `config/groups.conf` lists, named once, and each `CPUS` a positive decimal. The caps go into every run's `pending.json` as `"caps": {"ingot": "1.0", "piri-0": "1.0"}`. After setup, before `netem.sh apply`, `run.sh` runs `docker update --cpus <CPUS>` on each service's container and reads back `HostConfig.NanoCpus`; a failed update or a value that does not match stops the run with `runner_error`. `docker update` restarts nothing, and `netem.sh apply` records start times and addresses after it, so the post-check sees no change. `runner.json` keeps the caps for the raw tarball. The record carries only the flag `cpu_capped`, and a capped run is series `calibration` whatever the workers or `SERIES_LIVE` say, so it never lights a gate or moves the mercury. `--cap` runs only by hand on a held persistent box; `campaign.json` takes no caps, and `campaign.sh` refuses one that names them.

On a campaign box (`FORGE_PERF_MODE=campaign`) it takes no arguments and reads `/etc/forge-perf/campaign.json`, which the box's user data writes:

```json
{"mode": "campaign", "set": "calibration/sets/cal-1.json", "runs": 3, "size": "2000GB",
 "workers": [64], "duration": "4h", "forge_perf_sha": "<40-hex>", "expires_at": "2026-10-01T18:00:00Z"}
```

It checks out `forge_perf_sha` if the checkout is elsewhere and starts again from it; the box never runs `update.sh`. The bootstrap already armed a persistent `forge-perf-expire.timer` for `expires_at`; if that timer is not active, it schedules `systemctl poweroff` at `expires_at` with `systemd-run --on-calendar`, a transient timer that each boot sets again. Past that time it powers off at once. In mode `campaign` an error that stops it flushes the outbox and powers off once it has read `campaign.json`, so a checkout that fails does not leave the box idle until `expires_at`; the bootstrap's own failure powers the box off the same way. Mode `calibration` stops after the timer, leaving the box to the ceiling measurements, and an error leaves it up for the operator. Otherwise it runs the set, keeping its progress in `state/campaign-progress.json` so a reboot resumes after the last run that ended, flushes the outbox up to three times, and powers off. Before each run it checks that the run's duration plus 45 minutes for setup, record and wipe ends before `expires_at`; the first run that would not ends the campaign there. `forge-perf-campaign.service` starts it at every boot, and the bootstrap starts it on the first.

A run that the poweroff at `expires_at` still interrupts is recorded and wiped as the run unit stops. `forge-perf-final-flush.service`, enabled on campaign boxes only, does nothing at start; it is ordered before the run and campaign units and after `network-online.target`, so at shutdown it stops after them and while the network is up, and its `ExecStop` runs `outbox.sh flush` for up to 20 minutes. A campaign box has no poller to upload that run later, and the reaper's terminate deletes the root volume.

On a persistent box it refuses unless the box is held, and powers nothing off. [operations.md](operations.md#a-campaign) covers dispatching a campaign box and its reaper.

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

Without `--until`, the same command runs the whole run: netem, the drill, the post-check, the record, the upload and the wipe. The record and raw tarball land in `local/outbox`, then in the `local-results` bucket of the local MinIO through `AWS_ENDPOINT_URL`, and the wipe removes the stack and empties the `local-piri-0-*` buckets. Docker Desktop's VM adds a few milliseconds of timer slack to every delayed packet, so the netem checks usually need a wider band there; `NETEM_LOCAL=1` with a `RTT_TOLERANCE_PCT` in the environment widens it, and `latency.json` records that it was overridden. A laptop has no instance metadata, so in skip mode `runner.json` carries placeholder box facts the schema accepts: instance type `local.large`, zone `us-east-2a`, AMI `ami-00000000`, and memory 0 when unread. The box ID `local` marks such a record. A Mac that goes to idle sleep during a run holds the run until it wakes, and the record's times include the sleep; on macOS, put `caffeinate -i` in front of `scripts/host/run.sh` to keep the laptop awake until the run returns.

```sh
NETEM_LOCAL=1 RTT_TOLERANCE_PCT=40 PATH="$PWD/local/bin:$PATH" \
  scripts/host/run.sh --set calibration/sets/shakedown.json
aws s3 ls --recursive s3://local-results/
```

The poller runs the same way. In skip mode it flushes the outbox in its own process, never updates the checkout, and logs the dispatch as `host-op skipped: systemctl start --no-block forge-perf-run.service`; start the pending run by hand with `run.sh`, which takes `local/state/pending.json`. Without `flock` (macOS) a run counts as going while `local/state/current.json` exists.

A pass makes a set pending only when its key differs from `local/state/last-started.json`'s ([The decision](#the-decision)), and prints nothing when it does not. Every earlier run leaves that file, the `--until setup` run above included, and while `main` still carries the shakedown set's digests the pass then writes no `pending.json`. Remove the file first to poll from a clean state:

```sh
rm -f local/state/last-started.json
scripts/host/poll.sh                # resolves the set from GHCR, writes local/state/pending.json and a heartbeat
scripts/host/status.sh
NETEM_LOCAL=1 RTT_TOLERANCE_PCT=40 PATH="$PWD/local/bin:$PATH" scripts/host/run.sh
```

`poll.sh` takes each image's current digest, so the run pulls whatever `main` holds now. To run a pinned set as a per-trigger run instead, write `pending.json` from it and start `run.sh` the same way:

```sh
jq -n --slurpfile set calibration/sets/shakedown.json \
  '{kind: "trigger", set: $set[0], superseded: 0}' >local/state/pending.json
```

Instance metadata reports the type as `local` in skip mode, which selects `config/settings/local.env` (4 workers, 2 GB per run). At a laptop's rate that cap fills one to four 10-second windows, so a local run carries the `few_windows` flag, and its p5 and median can differ several-fold between two runs of the same set. A local run checks the pipeline end to end; it does not measure the rate. Its `DISK_FACTOR=1.25` is the box's value, and smelt's disk check counts only ingot's side. The local MinIO keeps piri's blobs on the same disk, so a laptop needs about twice the cap free. The host checks (clock, CPU, `sch_netem`) log `host-check skipped` and pass. A checkout with uncommitted changes stops preflight as on the box; `FORGE_PERF_ALLOW_MODIFIED=1` lets it through in skip mode only. `FORGE_PERF_CLIENT_PATH=published` sends the drill to ingot's published port through Docker's proxy, so a local run measures that path too. smelt's stack uses compose project `smelt`, `forge-network` and host ports 15000 to 15141, so it cannot run beside another smelt stack.

To remove the local setup, wipe first, then remove MinIO with its data and the local state:

```sh
scripts/host/wipe.sh
docker rm -f local-minio
rm -rf local
```

The credentials file sits outside `local/run/secrets`, which the wipe deletes. Skip mode leaves out what depends on the box itself: the instance-store format, `fstrim` and the page cache, the NIC counters and the NVMe free-space samples (the record's `network` fields are null), the unit's journal, the unit ordering after Docker, and AWS S3's network path.
