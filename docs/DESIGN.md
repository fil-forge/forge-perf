# forge-perf design

Line references point at these commits: fil-forge/smelt `878700b`, piri `448f702`, ingot `c08e0f1`, infra-nodes `82c23b2` and infra-central `05073ee` (each `main` on 2026-09-25); fil-one/storage-qualification `5cfeaf3`; and minio-go `v7.3.0`. storage-qualification is private; its references serve readers with access. **[unverified]** marks behavior the first boot or the calibration session must confirm; **[est]** marks an estimate.

## 1. What forge-perf measures

forge-perf tracks one number: the sustained ingest rate of the Forge storage stack under the storage-qualification drill's import profile (~128 MiB objects). The number is p5 of 30-second windows, the highest rate at least 95% of the windows held (`storage-qualification/internal/evidence/sustained.go:69-83`). The page shows the median beside it.

A dedicated EC2 box runs every Forge service from the published `ghcr.io/fil-forge/<svc>:main` images. A run starts whenever one of those images changes on main, or smelt does, or the harness (fil-one/storage-qualification, which builds the drill). The box pins every image by digest for the run, wipes everything afterwards, and publishes the result with the full commit and digest of every component.

The page shows the number as a thermometer. The mercury is the latest valid p5, and three gates mark the measured ceilings of three instance types: for each, the lower of its sustained S3 PUT throughput and its NVMe sequential write throughput. A gate lights when a valid run's p5 reaches it. Each ceiling measures one limit in isolation, so the stack's reachable rate sits below it. The top gate's instance has a raw NIC figure of 4.25 GB/s, above the drill's 3 GB/s target.

The one measurement so far comes from a laptop (50 GB cap, 10-second windows, piri on its filesystem, no added latency): 0.10 GB/s median and 0.04 GB/s p5, and none of 33,759 requests failed.

## 2. The topology modeled

The box models a production appliance at a storage provider's site about 25 ms round trip from AWS us-east-2 (Ohio), where the central services run. The appliance's blob storage is the provider's HDD-backed S3 service at the same site.

| Production | On the box |
|---|---|
| Appliance NVMe: OS, Postgres, ingot spool, Docker | Instance-store NVMe holds every Docker volume |
| Provider S3 behind piri, same site | AWS S3 in us-east-2 through a gateway endpoint, no added delay |
| Central services in Ohio | Same host, 25 ms round trip added between node and central containers |
| S3 clients at the appliance's site | Drill on the same host, Docker bridge to ingot, no added delay |
| No indexer or IPNI on dev and staging | piri's indexer and IPNI announce settings removed; sprue's indexer cleared |

Dev piri omits both indexer settings, which make `blob/accept` fail when no indexer answers (`infra-nodes/nodes/dev/apps/config/piri/piri-base-config.toml.tpl:33-36`). smelt's indexer, IPNI and redis containers stay up, idle, since ingot and piri depend on them (`smelt/systems/ingot/compose.yml:58`).

The page states these gaps beside the number:

- smelt's services talk plain HTTP/1.1, where production uses TLS and HTTP/2. The box therefore opens more TCP connections than production does, and it skips TLS and the proxy hop.
- Central services and the drill client share the host's CPU, and the client hashes every body with SHA-256.
- The added delay has no jitter or loss.
- AWS S3 is probably faster than the provider's HDD-backed S3.

smelt's ingot also follows swarf's revocation firehose and reaches OpenBao over TCP (`smelt/systems/ingot/config/config.yaml:45-46, 59`), which dev's ingot does not (`infra-nodes/nodes/dev/apps/config/ingot/config.yaml.tpl:72`).

## 3. The box and its tiers

One persistent box runs in the dev account (654654381893, us-east-2): tier 2, resized in place from tier 1 after gate 1 lit on 2026-09-28. Tier 3 exists only during campaigns: a short-lived box runs one committed set several times, publishes and is destroyed. All three are Graviton5 m9gd instances on one pinned arm64 Ubuntu 24.04 AMI; type and architecture are OpenTofu variables.

| Tier | Type | Cores | Memory | Instance store (4 KiB read/write IOPS) | Network | On-demand |
|---|---|---|---|---|---|---|
| 1 | m9gd.2xlarge | 8 | 32 GiB | 474 GB (174k / 87k) | 4.25 Gbps baseline, 17 burst | ~$367/month |
| 2 | m9gd.8xlarge | 32 | 128 GiB | 1,900 GB (698k / 349k) | 17 Gbps | ~$1,468/month |
| 3 | m9gd.16xlarge | 64 | 256 GiB | 3,800 GB (1.40M / 698k) | 34 Gbps | $4.02/hour, campaigns only |

Tier 1 costs $395 a month **[est]** with storage, IPv4 and S3 requests, and tier 2 about $1,500 **[est]**. An AWS budget on the `Project` tag alerts on overspend.

The instrument is everything that measures the Forge images: box type, AMI, kernel, Docker, smelt, the harness, the third-party images and forge-perf itself. Each change to it is a reviewed PR and a marker on the page.

### OpenTofu

The layout follows infra-nodes and infra-central (`versions.tofu`, a `versions.tf` refusing Terraform, provider `~> 6.0`, `allowed_account_ids`, `default_tags` with `Project = forge-perf`, committed tfvars, `shared/constants`), on OpenTofu 1.12.5.

| Root | Applied by | Holds |
|---|---|---|
| `envs/bootstrap/account` | operator | state bucket `forge-perf-tfstate-654654381893`, CI roles, results bucket, piri IAM user, budget |
| `envs/network` | `deploy.yml` on main | `172.31.200.0/24` in the default VPC, its route table and S3 gateway endpoint |
| `envs/box/main` | `deploy.yml` on main, after approval | the persistent box and its piri buckets |
| `envs/box/campaign` | `campaign.yml` | a campaign or calibration box, destroyed after use |

Each box root pre-creates piri's six buckets (`forge-perf-piri-<box>-654654381893-piri-0-<store>`, stores from `piri/pkg/fx/store/s3/provider.go:48-96`) with a one-day expiry. The security group has no ingress; Session Manager is the only way in. `ami_id` is pinned in the constants module, where infra-nodes looks its AMI up at create time (`infra-nodes/terraform/modules/node/main.tf:18-36`), because a new kernel is an instrument change. A resize or replacement mid-run would lose the run, so `apply-box-main` waits for a reviewer's approval, given once the box is held idle (§10).

The instance role reads `/forge-perf/*` parameters, writes its own prefixes of the results bucket without read or delete, and empties its own piri buckets. The OIDC roles follow `infra-central/terraform/modules/github-actions-iam/main.tf:23-48`: `forge-perf-ci-plan` for pull requests, `forge-perf-ci-apply` and `forge-perf-ci-results` for main. The account also holds dev, so the apply role cannot stop, modify, delete or retag an EC2 resource lacking `Project = forge-perf`. main carries infra-nodes' ruleset, since any merge to forge-perf, smelt or storage-qualification main, or a new tracked `:main` image, runs code on the box as root.

### Host

`provision.sh` is idempotent and pins the tools in `host/versions.env`: Docker CE and Compose from Docker's apt repository, held; Go 1.26 with `GOTOOLCHAIN=local`; ucantool v0.1.0 at infra-nodes' checksum, so smelt's `init.sh` never installs `@latest` (`smelt/scripts/init.sh:40-53`); AWS CLI v2. fio, jq, zstd, git, curl and the other Ubuntu archive tools are installed unpinned, and `scripts/host/box-facts.sh` reports the version of each. infra-nodes uses Ubuntu's `docker.io` (`infra-nodes/terraform/modules/node/files/bootstrap.sh.tftpl:29-40`), but `noble-updates` keeps only the newest build, and Docker's repository lets a replaced box install the same one. `provision.sh` also purges unattended-upgrades, holds kernel packages and snaps, loads `sch_netem`, `sch_prio` and `cls_u32`, and moves Docker's address pools to `10.213.0.0/16`, clear of the VPC. A run records the box facts (instance type, AMI, kernel, Docker, CPU and NVMe model) and refuses to start with an unsynchronized clock or on a CPU without `sha2`, since SHA-256 would fall back to software.

| Unit | What it does |
|---|---|
| `forge-perf-nvme.service` | formats the instance store before `docker.service` (§6) |
| `forge-perf-recover.service` | closes out a run a reboot interrupted |
| `forge-perf-poll.timer`, `forge-perf-nightly.timer` | call `poll.sh` every 5 minutes and at 03:00 UTC |
| `forge-perf-run.service` | `run.sh`; `Type=oneshot`, `TimeoutStartSec=6h`, `TimeoutStopSec=45min`, `KillMode=mixed`, `ExecStopPost=wipe.sh --if-dirty`, no `Restart=`, as infra-nodes' reconcile unit |
| `forge-perf-campaign.service` | campaign boxes only: one set, N times, each through `forge-perf-run.service` |

The units use `Wants=` and `After=docker.service`, since `Requires=` would stop them with Docker. Between runs `poll.sh` calls `update.sh`, modeled on infra-nodes' reconcile (`infra-nodes/scripts/host/reconcile.sh:16-29`, `infra-nodes/scripts/host/lib.sh:145-184`): re-exec from a copy, reset to `origin/main`, sync units, rerun `provision.sh` when `host/` changed, enable the units in `systemd/enabled.<mode>`. Campaign boxes never update.

## 4. A run from trigger to published result

Every five minutes a poll resolves a set: the smelt SHA, the harness SHA and the digest of every image under test. A run starts when the set differs from the last one started; the newest set wins, and at most one run is pending. A nightly run starts at 03:00 UTC regardless. There is no webhook, self-hosted runner or inbound port.

| Input | Resolved by | Triggers |
|---|---|---|
| `ghcr.io/fil-forge/{ingot,piri,sprue,hilt,swarf,delegator,piri-signing-service,did-method-plc,indexing-service}:main`, `guppy:main-dev` | anonymous GHCR manifest `HEAD` | yes |
| smelt main, storage-qualification main | `git ls-remote`; mirrors also fetch `refs/pull/*/head`, so a SHA outlives its branch | yes |
| postgres, openbao, dynamodb-local, redis, smtp4dev, storetheindex, filecoin-localdev, minio, netshoot | digests in `config/images.lock` | no; a bump is an instrument change |
| forge-perf | `update.sh` between runs | no |

Runs follow storage-qualification main, which accepts the `--stop-ingest-at` flag smelt's wrapper requires (`smelt/scripts/perf-drill.sh:241-252`). Setting `SQ_PIN` in `config/harness.conf` holds the harness at one commit instead, and harness main then does not trigger runs.

`/var/lib/forge-perf/state/` holds `pending.json`, `current.json` (with the run's phase), `last-started.json`, and a `hold` file that survives reboots. A set that ended `failed`, or `no_data` for a Forge-side reason, waits for the nightly. A set stopped by an infrastructure failure (image pull, SSM, S3, mirror fetch) is retried up to three times, 15 minutes apart. Each poll writes `published/<box>/heartbeat.json` and retries the outbox, a directory on root that holds uploads until S3 accepts them.

### Steps of one run

| Step | What happens | On failure |
|---|---|---|
| Before preflight | a settings file for the instance type, with `WORKERS` set; otherwise the run stops before it starts, with no record | none |
| Preflight | no containers, volumes or `forge-network`; empty piri buckets; synchronized clock; clean checkout; secrets from SSM to tmpfs | `no_data` |
| Checkout | smelt and the harness from the mirrors at the set's SHAs; build the drill | `no_data` |
| Images | set each image variable in `config/images.tracked` to `<repo>@sha256:<digest>`; pull what is missing; `docker compose config --images` lists only pinned digests | `no_data` |
| Boot, setup | `docker network create --subnet 172.30.0.0/24 forge-network`; `make up` with the rendered manifest, piri's S3 key and indexing off; `INGOT_URL=http://<ingot bridge IP> perf-drill.sh setup` | `no_data` |
| Latency | apply and verify netem (§5) | `invalid` |
| Drill | drop the page cache, snapshot NIC counters, `perf-drill.sh run` under `timeout --signal=INT --kill-after=5m` of `DURATION` + 30 min; watch free NVMe space | classified (§7) |
| Post-check | latency, restarts, central addresses, image IDs | `invalid` |
| Record, upload, wipe | build and check the record; upload raw, then record; wipe (§6) | minimal `no_data` record |

Each step runs under `timeout`; an overrun is reason `step_timeout`. `INGOT_URL` points the drill at ingot's bridge address (`smelt/scripts/s3-key.sh:67-68, 136`), bypassing Docker's userspace proxy.

### Drill settings

Values live in `config/settings/<instance type>.env`, so a resize without a settings file for the new type stops runs. Every flag is passed and recorded:

```
bin/drill --provider <run dir>/drill --profile import --stop-ingest-at 100GB \
  --ramp 10s --window 30s --verify-lag-min 30s --verify-lag-max 60s \
  --workers <frozen> --duration 1h --rate-target 6GB --accounts 64 \
  --restore-scale 0.25 --enforce-floor=false --progress 30s --keep-objects
```

- `--stop-ingest-at` is 100GB per trigger and 350GB nightly on tier 1; tier 1's nightly moves to 500GB once ingot's spool frees space (§10). Tier 2 takes 500GB per trigger and 1200GB nightly, so at about 2 GB/s its runs score about 8 and 20 windows. `--duration` is 1h per trigger and 4h nightly, enough for 100 GB above 0.028 GB/s and 350 GB above 0.024 GB/s, and on tier 2 for 500 GB above 0.14 GB/s and 1,200 GB above 0.083 GB/s. At 0.1 to 0.5 GB/s a tier 1 trigger run takes 10 to 30 minutes **[est]**.
- `--ramp 10s`: with fixed workers the ramp only delays measurement while its bytes count toward the cap (`storage-qualification/internal/drill/drill.go:604-627`).
- `--rate-target 6GB` is above every tier's ceiling. The drill paces restores from the same rate (`storage-qualification/internal/drill/drill.go:178-179`), so one value keeps the workload equal across tiers.
- `--accounts 64 --restore-scale 0.25` are the import profile's own values (`storage-qualification/internal/drill/profile.go:126`). `--keep-objects` skips the drill's sweep; the wipe deletes everything.

## 5. Latency simulation

A fixed 25 ms round trip, with no jitter and no bandwidth cap, separates the node group from the central group. netem, the Linux kernel's delay-and-loss queueing discipline, runs in each node container's network namespace and delays only packets addressed to central containers.

| Group (`config/groups.conf`) | Services | Treatment |
|---|---|---|
| node | `ingot`, `ingot-postgres`, `ingot-openbao`, `piri-0`; `piri-postgres` sits only on `piri-storage-net` | prio qdisc with netem |
| central | `upload`, `postgres`, `hilt`, `hilt-postgres`, `hilt-vault`, `swarf`, `swarf-postgres`, `plc`, `plc-postgres`, `delegator`, `signing-service`, `dynamodb-local`, `minio` | filter targets |
| other | `blockchain`, `email`, `guppy`, `indexer`, `redis`, `ipni`, `piri-minio`, the host, AWS S3 | undelayed |
| one-shot | `ingot-openbao-init`, `piri-postgres-init`, `upload-init`, `hilt-init`, `ipni-init` | must have exited 0 |

A service in no list stops the run. `netem.sh apply` runs a pinned netshoot sidecar with `NET_ADMIN` in each shaped container, picks the interface holding its forge-network address (piri-0 has two), and installs:

```sh
tc qdisc add dev "$dev" root handle 1: prio bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
tc qdisc add dev "$dev" parent 1:4 handle 40: netem delay 25ms limit 100000
tc filter add dev "$dev" parent 1: protocol ip prio 1 u32 match ip dst <central-ip>/32 flowid 1:4
```

The all-zero priomap keeps unfiltered traffic in band 1. Delaying node egress adds one round trip to every exchange across the boundary, handshakes included. Healthchecks and Docker's DNS stay on loopback, undelayed.

`netem.sh verify` runs before and after the drill. Across the boundary, in both directions, the median of 20 pings per pair and the median of 10 TCP connects must fall between 22.5 and 27.5 ms; within a group, and from the host to ingot, the median stays under 1 ms. A container that is gone or not running fails the check, and its probes are skipped. Afterwards the qdiscs must be present, and central addresses, container IDs and restart counts unchanged. A failure makes the run `invalid`, numbers kept. A restarted central container (`restart: unless-stopped`, `smelt/systems/upload/compose.yml:41`) can return on an address the filter no longer matches. Calibration also moves 1 GiB from ingot to piri-0 with and without the qdisc; the rates must agree within 5%.

## 6. Storage and the wipe

All run data lives on the instance-store NVMe: every Docker named volume, through a bind mount at `/var/lib/docker/volumes`, and the per-run checkouts and run directory under `/mnt/forge-perf/nvme/work`. The gp3 root keeps what a wipe spares: pinned images, Go caches, the forge-perf checkout, git mirrors, the journal and the outbox. The AWS CLI files `s3-key.sh` writes (`smelt/scripts/s3-key.sh:133-134`) go to tmpfs through `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE`.

Binding the whole directory catches every named volume smelt creates, future ones included. Central Postgres sits on the NVMe too, so a slow central fsync cannot read as a slow ingot. `forge-perf-nvme.service` takes the one device whose model is `Amazon EC2 NVMe Instance Storage` (`lsblk -dno PATH,MODEL`) and formats it at every boot as ext4, like the infra-nodes data volume (`infra-nodes/terraform/modules/node/files/bootstrap.sh.tftpl:70`), initializing eagerly so no kernel thread writes across the drive during the next ingest:

```sh
mkfs.ext4 -F -q -m 0 -L forge-perf-nvme -E lazy_itable_init=0,lazy_journal_init=0 "$dev"
```

After a plain reboot with a run in progress, the unit mounts without formatting, and recovery stops the containers Docker restarted, collects their logs and the run directory, then wipes. A stop/start or resize always starts from a blank drive.

The wipe, in order:

1. `make nuke YES=1` in the smelt checkout (`smelt/Makefile:246-257`).
2. Remove every remaining container, every volume by name, and `forge-network`. `docker volume prune` touches only anonymous volumes.
3. Empty the six piri buckets and abort their incomplete multipart uploads.
4. Delete the work tree, check that no volume remains, and `fstrim` the mount.
5. Drop the page cache, remove images outside the pinned set, delete secrets from `/run`.

The wipe never stops Docker, so it can run inside a unit ordered after Docker.

smelt's disk check needs `DISK_FACTOR × STOP_INGEST_AT` free on ingot's `/data` (`smelt/scripts/perf-drill.sh:307-324`). With piri's blobs in S3 only the spool grows, and it keeps every ingested byte until ingot's spool cleanup lands (fil-forge/ingot#48). `DISK_FACTOR=1.25` covers spool, Postgres, catalog and logs **[est]**. On tier 1, 350 GB needs 437.5 GB of the 466 GB **[est]** that ext4 leaves on the 474 GB drive; on tier 2, 1,200 GB needs 1,500 GB of about 1,863 GB **[est]** on the 1,900 GB drive. The first 100 GB run checks the factor against `du` of the volumes, and a run whose free space falls under 2 GB ends `invalid` (`disk_low`).

## 7. Results and the page

Raw run data stays in a private bucket. The public record carries a fixed allowlist: rates, counts, outcome class, settings, measured round trips, box facts, full SHAs and image digests. A scheduled Action reads records through an OIDC role, commits them to the `results` branch and deploys GitHub Pages, so the box holds no GitHub write credential and no Slack credential.

```
box ──► s3://forge-perf-results-654654381893/raw/<box>/<run_id>/raw.tar.zst   private
    └─► s3://forge-perf-results-654654381893/published/<box>/<run_id>.json    allowlisted record
publish.yml, every 15 min, one at a time, role forge-perf-ci-results
    ├─ validate, commit to branch results as runs/<yyyy>/<mm>/<run_id>.json
    └─ build the site from site/, data/ and the records; deploy Pages
```

The bucket is versioned; `raw/` expires after 180 days, `published/` after 90, and the results role cannot read `raw/`. Raw tarballs go up with `aws s3 cp` and a SHA-256 checksum, records with `aws s3api put-object --content-md5 --if-none-match '*'`, so no record is overwritten. A zero exit, or a 412 on a record, clears its outbox entry.

`piri init` prints its config, S3 secret included, on every fresh volume (`piri/cmd/cli/setup/register.go:1086-1105`, `smelt/systems/piri/entrypoint.sh:98-110`). `run.sh` strips those lines before tarring, leaves out the drill's `provider/.env`, and refuses to upload while any piri or harness credential remains in the tree.

### The record

Run IDs are `<box>-<yyyymmdd>t<hhmmss>z` (`main-20261001t120312z`), taken from `time.run_started_at`, and double as smelt's `LABEL`. `schema/run-record.v1.json` sets `additionalProperties: false` everywhere and has no free-text field: every string is an enum, SHA, digest, timestamp, duration or patterned version.

| Group | Contents |
|---|---|
| identity, `time` | `run_id`, `series` (`per-trigger`, `nightly`, `campaign`, `calibration`), `pairing_id`, trigger reason, changed components; UTC `run_started_at`, `stack_up_at`, `drill_started_at`, `drill_finished_at`, `run_finished_at` |
| `box`, `outcome` | box facts; class, reasons, flags, drill exit code and failure codes |
| `drill` | every setting; p5, median and per-window ingest rates; window, byte, blob, request and error counts; piri's failed S3 PUTs (`piri/pkg/store/objectstore/minio/minio.go:67`), which separate S3 incidents from Forge errors; read-back and restore rates, marked `cache_served` because read-back runs 30 to 60 seconds after each write |
| `latency`, `network` | measured round trips before and after; changes in the Elastic Network Adapter's allowance-exceeded counters; egress rate |
| `provenance` | forge-perf, smelt and harness SHAs; each image's repository, digest, revision label and role (`under_test` or `instrument`) |
| `instrument`, `trace` | two fingerprints; `null` until the tracing phase |

The record builder copies named fields and nothing else, because the drill's report, console output, evidence notes and failure details are free text; it takes `failures[].code`, a closed set, and named numeric facts. The box checks the record against the schema, a denylist pattern and piri's key ID. The Action repeats the checks, using the schema at the record's own forge-perf SHA, and recomputes the fingerprints; `check.yml` runs the denylist over the tree and commit messages.

One fingerprint hashes the box facts and one the rest of the instrument, minus forge-perf paths in `config/not-instrument` such as `site/`. The page marks a run whose fingerprints differ from the previous run in its series and lists what changed.

### Outcome classes

| Class | When | Mercury, gates | Slack |
|---|---|---|---|
| `no_data` | runner error, stack or setup failed, drill exit 2, `wrote_nothing`, no evidence, interrupted, step timeout, infrastructure failure, record build failed | no | yes; infrastructure only on the third in a row |
| `failed` | integrity failures, or a drill failure code no other class lists | no | on integrity |
| `invalid` | latency check failed, container restarted, image changed, harness mismatch, `read_back_incomplete`, `ingest_cutoff_before_measurement`, no steady windows, disk low, modified checkout, dirty start | no | on latency or restart |
| `availability_warning` | only `availability_error`; the import client does not retry, so one 5xx fails a capped run | shown, numbers kept | no |
| `valid` | drill exit 0, every check passed | yes | one message saying the box recovered |

Flags leave the class alone: `few_windows` (under 20 steady windows, where p5 is the slowest window, `smelt/docs/PERF_TESTING.md:215-216`), `cap_not_reached`, `nic_allowance_exceeded`, `offered_rate_near_median`, `superseded`, `raw_missing`, `cpu_capped`. A reviewed PR to `data/overrides.json` citing an issue can reclassify a run; records are never edited.

`publish.yml` posts to `#filone-alerts` with `SLACK_BOT_TOKEN`, as `infra-nodes/.github/workflows/smoke.yml:205-238` does, once per box and class until that box records `valid` or `availability_warning`. It also alerts once when the persistent box's heartbeat is 30 minutes old, six polls in a row fail, one run has held the box for 7 hours, or no record has arrived in 26 hours. GitHub disables scheduled workflows in a public repository after 60 days without activity, so the page shows when it was last published.

### The page

A static site in `site/`, with Observable Plot and d3 vendored:

1. The thermometer beside the headline numbers in text. The mercury is the latest valid per-trigger or nightly p5 on the persistent box, with its age and a pointer at its median. Gates come from `data/gates.json`; an unmeasured gate is `null` and drawn dashed. Valid per-trigger, nightly and campaign runs light gates; `calibration` runs never do. With no valid per-trigger or nightly run on the persistent box, the headline gives the latest run's class and reason.
2. History, one series at a time: p5 line, dashed median, gate lines, markers for instrument and box changes.
3. The runs table, opening `#run=<run_id>` with every record field, compare links against the previous run, and the harness SHA as plain text.
4. How it is measured: the method, the workload (the drill's import profile, ~128 MiB objects) and the gaps from §2.

## 8. smelt changes

Five upstream PRs give smelt every setting forge-perf needs. Each is opt-in and reproduces today's stack when unset, so forge-perf keeps no compose override file. All five are on smelt main, which runs follow.

| PR | Change | forge-perf sets |
|---|---|---|
| 1. piri on external S3 | manifest `storage.s3` (`endpoint`, `bucket_prefix`, `insecure`) replaces the hard-coded MinIO (`smelt/pkg/generate/compose.go:41-44, 90-96`); credentials from the shell, empty ones refused | regional endpoint, box prefix, `SMELT_PIRI_S3_*` |
| 2. Indexing off | `PIRI_INDEXER=off` drops piri's indexer and IPNI settings; sprue's indexer variables pass through | `PIRI_INDEXER=off SPRUE_INDEXER_ENDPOINT= SPRUE_INDEXER_DID=` |
| 3. Third-party images | `${POSTGRES_IMAGE:-postgres:16-alpine}`, and the same for OpenBao, redis, dynamodb-local and smtp4dev | `config/images.lock` digests |
| 4. Record what ran | full SHAs; each image's digest and revision (today short sibling SHAs, `smelt/scripts/perf-lib.sh:37-67`); all settings; `PERF_EXTRA_METADATA` | run ID, series, box |
| 5. Drill flags, disk check | one recorded variable per drill flag; `DISK_FACTOR` in place of the fixed 2.5; host check only on Docker Desktop | §4 flags, `DISK_FACTOR=1.25` |

PR 5 stacks on PR 4; the others are independent. piri needs no region setting: minio-go v7.3.0 derives us-east-2 from the endpoint `s3.us-east-2.amazonaws.com` (`minio-go/api.go:299-303`). A sixth PR, for the tracing phase, passes `OTEL_RESOURCE_ATTRIBUTES` to ingot, sprue and hilt, which already read it (`ingot/cmd/telemetry.go:51`).

## 9. Calibration and ceilings

One session measures all three instance types in turn. A tier's ceiling is the lower of two measurements, each scored as p5 of 30-second windows over its sustained segment.

**S3 PUT.** `cmd/s3-ceiling` reproduces piri's call: minio-go v7.3.0 (piri's pin, `piri/go.mod:44`; CI fails if they diverge), TLS to the regional endpoint, piri's static key, `PutObject` of 134,217,728 bytes from a non-seekable body into the box's own `pdp` bucket, 8 workers per core. AWS documents burst bandwidth as lasting typically 5 to 60 minutes. On m9gd.2xlarge the phase therefore runs 75 minutes and scores its last 30, starting once `bw_out_allowance_exceeded` has risen steadily for 5 minutes (counter name **[unverified]**). The larger types are rated sustained and run 30 minutes.

**NVMe write.** `scripts/host/ceiling-nvme.sh` discards the device and runs `fio --direct=1 --ioengine=io_uring --rw=write --bs=1M --iodepth=32 --numjobs=4 --size=25% --offset_increment=25%` over it. A 100 GB file write on ext4 sets the ceiling instead if it lands more than 10% lower. Tier 1's drive is rated at 87,209 4 KiB write IOPS (0.36 GB/s at that size), so it may set gate 1 below the NIC's 0.53 GB/s.

For each type, `campaign.yml` with `mode=calibration` starts a box and `scripts/operator/calibrate-ceilings.sh <type>` measures it over SSM and tears it down. Evidence lands in `calibration/ceilings/<date>/<type>/` and the gates in `data/gates.json`, in one reviewed PR. A session costs under $25 **[est]**.

**Tier 1 calibration** takes 20 runs and 12 hours of box time **[est]** on one committed set (`calibration/sets/cal-1.json`). Until it passes, `config/launch.conf` labels every run `calibration`.

1. Workers sweep: 16, 32 and 64, two 100 GB runs each, in the order 16, 32, 64, 64, 32, 16. The smallest value within 5% of the best mean p5 and median wins; an availability error disqualifies a value.
2. Repeat runs: five at 100 GB and three at 350 GB give each series its noise band, the range an unchanged stack falls in (`calibration/noise/main-<series>.json`). The drill draws a new blob-size seed every run, so the band includes that variation. Above 10% coefficient of variation the series stays unpublished. If the first steady window is consistently the lowest, `RAMP` goes to 30s.
3. Falsification: an older digest for one service, from a merged performance PR, must land below the per-trigger band in three runs of three, and so must a run with ingot capped at one CPU (`docker update --cpus 1.0`). That check runs on a held persistent box as `campaign.sh --cap ingot=1.0,piri-0=1.0`, which caps piri-0 as well and publishes every run as series `calibration` with the flag `cpu_capped`.

A run has about cap ÷ (rate × 30 s) windows. At 0.53 GB/s, 100 GB gives 6, 350 GB gives 22 and 500 GB gives 31; at 2.1 GB/s, 500 GB gives 7. Any valid run can light a gate, and one under 20 windows carries `few_windows`. Tier 3 campaigns run 2 TB, which gives 22 windows at 3 GB/s.

## 10. Operations

**Access:** `scripts/operator/ssm-session.sh main`, then `scripts/host/status.sh` for the hold, sets, last run and timers. `scripts/operator/hold.sh main on|off` sets the hold once the box is idle, and `box-update.sh main` runs `update.sh` over SSM.

**Tier 1 to tier 2**, when gate 1 lights:

1. `hold.sh main on`. `scripts/operator/set-from-record.sh <run_id>` writes the set of the run that lit gate 1 to `calibration/sets/tier2-bridge.json`; run `campaign.sh --set <file> --runs 3 --pairing <id>` at both sizes.
2. Merge a PR setting `instance_type = "m9gd.8xlarge"` in `terraform/envs/box/main/terraform.tfvars` and adding `config/settings/m9gd.8xlarge.env` with `WORKERS` empty. After approval, `deploy.yml` stops, modifies and starts the same instance.
3. Check the new NVMe, sweep workers at 1×, 2× and 4× the tier 1 value, freeze `WORKERS` in a PR, repeat the paired runs at the tier 1 sizes, release the hold. The page shows the box change and the offset between paired medians; past values never change.

**A tier 3 campaign:** commit a set and dispatch `campaign.yml` (`instance_type`, `hours` from 1 to 24, `set`, `runs`, `size`, `workers`, `duration`, `mode`). The box sweeps workers when given a list, runs the set, uploads and powers off, and schedules its own poweroff at its `ExpiresAt` tag. A `down` dispatch or the hourly reaper destroys it; the reaper takes any forge-perf instance other than `main` that is past `ExpiresAt` or stopped for an hour. A forgotten 12-hour campaign costs at most $52.

**Nightly to 500 GB on tier 1** once a spool budget lands on ingot `:main` (fil-forge/ingot#184, `spool_max_bytes`, a draft): one PR sets the budget and the cap, and three runs rebuild the nightly band. Evicted blobs then come back from S3, adding GETs to the NIC.

| Secret | Where | Rotation |
|---|---|---|
| piri's S3 key (IAM user `forge-perf-piri`, usable only through the forge-perf S3 gateway endpoint) | SSM `/forge-perf/piri-s3-*` | 90 days, two keys overlapping; made by hand so it never enters state |
| read-only access to fil-one/storage-qualification: a dedicated GitHub App (Contents: read, installed on that repository alone) | SSM `/forge-perf/harness-app` | the App key yearly, and when someone with access leaves |
| denylist pattern | SSM `/forge-perf/denylist`; secret `PUBLIC_DENYLIST_REGEX` | on change |
| `SLACK_BOT_TOKEN` | repository secret | with the Slack app |

**Alerts.** A boot failure usually means a new `:main` image needs a smelt change; a container restart mid-run is a bug in that service; an integrity failure is reproduced once with `run.sh --set <that set> --series calibration` before anyone blames a PR.

## 11. Later phases

**Dev as deployed.** After ingot's spool cleanup lands, a 5 to 10 GB drill after each dev deploy becomes its own series: schema v2 adds `dev` to `series` and a `target`. With 2 to 7 windows per run, that series reports the median.

**Tracing.** Every run records its ID and absolute times, and the record reserves `trace`. Tracing needs smelt PR 6, a piri change to read `OTEL_RESOURCE_ATTRIBUTES`, traces shipped before the wipe, and sampling, since a 500 GB run makes about 340,000 requests. Turning it on is an instrument change.

**Manual runs and bisect.** `run.sh --set <file>` ships with the first version; a later queue only writes set files. Some old digests will not boot against current smelt.

## 12. Open questions

| Question | Behavior until decided |
|---|---|
| Should only runs with 20 or more steady windows light a gate? A 100 GB run at gate 1 has about 6. | any valid run lights a gate |
| Can an `availability_warning` run light a gate? | no |
| Can a tier 1 run above the NIC baseline light gate 1? | yes, flagged |
| Keep the stack after an integrity failure? | wiped |
| Should guppy and indexing-service, off the drill path, trigger runs? | they trigger runs |
| A weekly reference run of `cal-1` to separate host drift from code? | none |
| Log scale for the thermometer? At 0.04 GB/s a linear tube is 1% full. | linear |
| Does ingot's catalog shipping, with sprue's indexer cleared, back up over 500 GB? | measured on the first such run |
| **[unverified]** Graviton5 support in the pinned kernel; ENA counter names; the instance-store model string; m9gd in us-east-2a; `172.31.200.0/24` free; `--if-none-match` in the pinned AWS CLI; the AMI's time source; whether the Action's pushes count as activity for GitHub's 60-day rule | first boot and calibration |
