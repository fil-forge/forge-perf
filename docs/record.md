# The run record

Every run ends in one JSON record, `forge-perf.run/v1`, defined by [`schema/run-record.v1.json`](../schema/run-record.v1.json). It is the only thing about a run that becomes public. [DESIGN.md §7](DESIGN.md#7-results-and-the-page) gives the context.

The schema sets `additionalProperties: false` on every object and has no free-text field: every string is an enum, a SHA, a digest, a timestamp or a patterned version. A new field is a schema change. `scripts/host/schemacheck.py <schema> <record>...` checks records with the standard library alone, so the box, CI and the publish Action run the same check. It refuses a schema that uses a keyword it does not implement, and its errors name the path and the rule but never the value.

## What the builder reads

The builder copies named fields from three inputs and reads nothing else.

| Input | Written by | What the builder takes |
|---|---|---|
| the smelt run directory | `perf-drill.sh run` | `metadata.json`; the one `drill/evidence/drill-*.json`; the count of `failed to put object` lines in `logs/piri-0.log` |
| `netem/latency.json` | `netem.sh verify pre` and `post` | both passes' summaries, pairs, connects and check lines |
| `runner.json` | `run.sh` | what only the runner knows, below |

The drill's report, `drill.out`, `stats.csv`, the other service logs, the provider `.env`, and the free-text parts of the evidence (`failures[].detail`, the `facts` map as a whole, `facts.notes`, `downgrades`, `provider`) are never read. From the evidence the builder copies `failures[].code`, a closed set (storage-qualification `internal/evidence/codes.go`), and named numeric facts. From `metadata.json` it never copies `host`, `manifest`, `images`, `suite.tenant`, `suite.config_note`, `suite.argv` or `extra`; it uses `suite.argv`, `extra.forge_perf.run_id` and the `images` labels only to check that the run directory belongs to this run.

`runner.json` holds:

| Field | Meaning |
|---|---|
| `run_id`, `series`, `pairing_id`, `trigger`, `box`, `time` | copied into the record unchanged |
| `superseded` | how many pending sets the run's set replaced (`pending.json`) |
| `settings` | the drill settings from `config/settings/<instance type>.env`, in the record's units; null when the file is missing or unreadable |
| `provenance.forge_perf`, `provenance.smelt.sha`, `provenance.harness.sha` | the SHAs the run used, which its checkouts hold once checked out |
| `images[]` | the pinned set: `variable`, `repo`, `ref` (the tag), `digest`, `role`; `services`, the compose services that run the image; and `revision` and `source`, the image's `org.opencontainers.image.revision` and `org.opencontainers.image.source` labels from `docker image inspect` once the image is present, null before that or without the label |
| `reasons[]`, `restarted_services[]` | what the runner found itself: a failed or timed-out step, an infrastructure failure, a changed image, low disk, a dirty start, an interrupt it caused |
| `watchdog_fired` | the drill's `timeout` fired |
| `nic` | `allowance_exceeded` deltas, `egress_bytes_per_s_median` and `seconds_above_baseline` from `ethtool -S` and the one-second interface samples |
| `raw_missing` | the raw tarball could not be built, was dropped from the outbox, or failed to upload for 24 hours |

`scripts/host/record.py` is the builder:

```
record.py build --runner runner.json [--run-dir DIR] [--latency netem/latency.json] \
                --denylist FILE [--forbid FILE] --out record.json
record.py minimal --runner runner.json --denylist FILE [--forbid FILE] --out record.json
```

Before writing, it checks the record against the schema, the denylist patterns (one per line, matched without regard to case) and the literal strings in `--forbid`, such as piri's S3 key ID. The denylist file is shared with CI's `grep -E -i`, so its patterns must mean the same to both: the builder refuses a pattern that uses `\<`, `\>` or a `[[:class:]]` bracket, or that Python cannot compile. `build` writes the minimal record below in place of a full record that stops, fails or is refused; `minimal` writes it directly, for a runner whose `build` call died. For `build`, exit status 0 means the full record was written and 3 the minimal record. For `minimal`, 0 means the minimal record was written. For both, 1 means nothing was written, because an input could not be read or even the minimal record was refused, and 2 is a usage error. Messages name the check or stage that failed, never an input's value.

When the drill never ran there is no run directory, and the builder uses `runner.json` and whatever `latency.json` holds. When `extra.forge_perf.run_id` differs from `runner.json`'s `run_id`, `suite.argv` disagrees with `settings`, or a `metadata.json` image's `revision` or `source` differs from `runner.json`'s for the same digest, the builder stops and writes the minimal record below.

## Field sources

| Record path | Source |
|---|---|
| `schema` | constant `forge-perf.run/v1` |
| `run_id` | runner: `<box.id>-<run_started_at as yyyymmddThhmmssZ, lowercased>`; also smelt's `LABEL` |
| `series` | runner: `per-trigger`, `nightly`, `campaign`, or `calibration` while `config/launch.conf` has `SERIES_LIVE=0` |
| `pairing_id` | runner: set on the paired runs that splice a tier change, else null |
| `trigger.reason` | runner: what started the run, from the triggers table below |
| `trigger.changed` | runner: the component ids whose digest or SHA in the run's set differs from the set in `last-started.json` before this run replaces it, sorted. A component id is a tracked image's repository name (`ingot`, `sprue`, `piri-signing-service`, `did-method-plc`), `smelt` or `harness` |
| `box.id`, `box.tier` | the box's OpenTofu-rendered config |
| `box.instance_type`, `box.availability_zone`, `box.ami_id` | IMDSv2 `instance-type`, `placement/availability-zone`, `ami-id` |
| `box.arch` | `uname -m`, with `aarch64` written as `arm64` |
| `box.region` | constant `us-east-2` |
| `box.kernel` | `uname -r` |
| `box.docker_server` | `docker version --format '{{.Server.Version}}'`; null when Docker does not answer |
| `box.docker_compose` | `docker compose version --short`; null when it fails |
| `box.cpu.implementer`, `box.cpu.part` | `/proc/cpuinfo` `CPU implementer` and `CPU part`; null on x86 |
| `box.cpu.cores` | `nproc` |
| `box.cpu.features` | `/proc/cpuinfo` `Features` (arm64) or `flags` (x86), in file order |
| `box.mem_total_bytes` | `/proc/meminfo` `MemTotal` × 1024 |
| `box.nvme.model`, `box.nvme.size_bytes` | `lsblk -bdno MODEL,SIZE` of the instance-store device; null when the device is missing |
| `box.nvme.filesystem` | `findmnt -no FSTYPE /mnt/forge-perf/nvme`; null when nothing is mounted there |
| `time.run_started_at` | runner clock when the run takes the lock |
| `time.stack_up_at` | `make up` returned zero; null if it never did |
| `time.drill_started_at`, `time.drill_finished_at` | when the runner starts `perf-drill.sh run` under the drill's `timeout`, and when that returns; null if it never started. A set `drill_started_at` is how the builder knows the drill started when there is no run directory |
| `time.run_finished_at` | the record is built |
| `outcome.class` | classification, below |
| `outcome.reasons` | every reason found, in the order of the reasons table |
| `outcome.restarted_services` | services named by `container_restarted`, sorted; each is a service in `config/groups.conf` outside `ONESHOT` |
| `outcome.flags` | every flag that applies, in the order of the flags table |
| `outcome.drill_exit` | `metadata.json` `suite.drill_exit` when it is 0, 1 or 2; null when the drill never ran, when the value is missing (the watchdog's kill also ends `perf-drill.sh`), and for any other status, such as 137 after an out-of-memory kill |
| `outcome.failure_codes` | the distinct `code` values of the evidence's top-level `failures` and `drill.failures`, sorted |
| `drill.settings` | runner `settings`; null when the settings file is missing or unreadable, which is `preflight_failed` |
| `drill.settings.profile` | constant `import` |
| `drill.settings.manifest` | runner: the name of the rendered smelt manifest template |
| `drill.settings.window_s`, `drill.settings.ramp_s`, `drill.settings.duration_s`, `drill.settings.verify_lag_min_s`, `drill.settings.verify_lag_max_s`, `drill.settings.progress_s` | runner settings; the same durations as `--window`, `--ramp`, `--duration`, `--verify-lag-min`, `--verify-lag-max`, `--progress`, in whole seconds |
| `drill.settings.workers`, `drill.settings.accounts` | `--workers`, `--accounts` |
| `drill.settings.rate_target_bytes_per_s`, `drill.settings.stop_ingest_at_bytes` | `--rate-target`, `--stop-ingest-at`, in bytes (GB = 10^9) |
| `drill.settings.restore_scale_permille` | `--restore-scale` × 1000, an integer so the fingerprint never hashes a float |
| `drill.settings.enforce_floor`, `drill.settings.keep_objects` | `--enforce-floor`, `--keep-objects` |
| `drill.results` | null unless the evidence exists and the drill exited 0 or 1 |
| `drill.results.sustained_windows` | evidence fact `sustained_windows`; 0 when absent |
| `drill.results.total_windows` | length of evidence `drill.windows`; 0 when absent |
| `drill.results.ingest_p5_bytes_per_s` | fact `sustained_ingest_p5_bytes_per_second`: the highest rate at least 95% of the steady windows held |
| `drill.results.ingest_median_bytes_per_s` | fact `sustained_ingest_median_bytes_per_second` |
| `drill.results.writes_median_per_s` | fact `sustained_writes_median_per_second` |
| `drill.results.window_ingest_bytes_per_s` | each window's `ingest_bytes_per_second`, in window order |
| `drill.results.cache_served.read_back_median_bytes_per_s` | fact `sustained_read_median_bytes_per_second`. Read-back runs 30 to 60 seconds after each write, so the page cache serves most of it |
| `drill.results.cache_served.restore_median_bytes_per_s` | fact `sustained_restore_median_bytes_per_second`, under the same caveat |
| `drill.results.ingest_sent_bytes` | fact `ingest_sent_bytes` |
| `drill.results.bytes_ingested`, `drill.results.bytes_read_back`, `drill.results.bytes_restored` | evidence `drill.bytes_ingested`, `bytes_read_back`, `bytes_restored` |
| `drill.results.blobs_written` | fact `blobs_written` |
| `drill.results.cap_reached` | fact `ingest_cutoff_reached` |
| `drill.results.ingest_cutoff_s` | fact `ingest_cutoff_seconds`; null when the cap was not reached |
| `drill.requests` | null under the same rule as `drill.results` |
| `drill.requests.total`, `drill.requests.transport_errors`, `drill.requests.status_408`, `drill.requests.status_429`, `drill.requests.status_5xx` | evidence `drill.availability` `requests`, `transport_errors`, `status_408`, `status_429`, `status_5xx` |
| `drill.requests.integrity_failures` | evidence `drill.integrity_failures` |
| `drill.requests.backend_s3_errors` | lines containing `failed to put object` in `logs/piri-0.log`, piri's log when an S3 PUT fails (`piri/pkg/store/objectstore/minio/minio.go:67`); null when the log is missing. It separates an S3 incident from a Forge error |
| `latency.target_rtt_ms`, `latency.tolerance_pct` | `latency.json` `rtt_ms` and `tolerance_pct` of the pre pass, else the post pass; `config/latency.env` when no pass ran |
| `latency.jitter_ms` | constant 0 |
| `latency.pairs` | cross-boundary pairs in the pre pass; 0 when it did not run |
| `latency.before`, `latency.after` | a summary of the pre and post passes (`rtt`, below); null when the pass did not run |
| `latency.max_drift_pct` | the largest `abs(median_ms - rtt_ms) / rtt_ms × 100` over both passes' cross pairs, rounded to 2 places; null with no measured pair |
| `latency.central_ips_stable` | false when the post pass has an `address changed from` line; null without a post pass |
| `network.allowance_exceeded` | runner `nic.allowance_exceeded`; null when `ethtool -S` failed or the drill never started |
| `network.allowance_exceeded.bw_in`, `network.allowance_exceeded.bw_out`, `network.allowance_exceeded.pps`, `network.allowance_exceeded.conntrack`, `network.allowance_exceeded.linklocal` | the start-to-end delta of the ENA counters `bw_in_allowance_exceeded`, `bw_out_allowance_exceeded`, `pps_allowance_exceeded`, `conntrack_allowance_exceeded`, `linklocal_allowance_exceeded` |
| `network.egress_bytes_per_s_median` | runner `nic`: the median of the interface's one-second transmit rate over the drill; null when the samples are missing or the drill never started |
| `network.seconds_above_baseline` | runner `nic`: seconds whose transmit rate exceeded `BASELINE_BYTES_PER_S` in `config/settings/<instance type>.env`, the instance type's baseline bandwidth; null when that line or the samples are missing, or the drill never started |
| `provenance.forge_perf.sha` | `git rev-parse HEAD` of the box's forge-perf checkout |
| `provenance.forge_perf.instrument_tree` | the instrument tree hash, below |
| `provenance.smelt.sha` | the smelt SHA in the run's set, which is `git rev-parse HEAD` of the run's smelt checkout once it is checked out. smelt's own `metadata.json` `repos` is not used |
| `provenance.harness.sha` | the harness SHA in the run's set, which is `git rev-parse HEAD` of the storage-qualification checkout once it is checked out |
| `provenance.harness.modified`, `provenance.harness.go_version`, `provenance.harness.binary_sha256` | evidence `provenance.harness_modified`, `go_version`, `binary_sha256`; null without evidence or when the harness wrote an empty string |
| `provenance.images` | one entry per image in the runner's pinned set, sorted by `repo` |
| `provenance.images[].repo`, `provenance.images[].ref`, `provenance.images[].digest`, `provenance.images[].role` | the pinned set; `role` is `under_test` for the tracked `ghcr.io/fil-forge/<svc>` images and `instrument` for the third-party images in `config/images.lock` |
| `provenance.images[].services` | `runner.json` `images[].services`: the services whose image in `docker compose config --format json` of the rendered manifest has the pinned digest, sorted. The netshoot image lists `netem`, the sidecar `netem.sh apply` starts, whenever the manifest was rendered, whether or not netem ran. The list is empty when the run stopped before the manifest was rendered |
| `provenance.images[].revision` | `runner.json` `images[].revision`, when it is 40 hex characters; else null. A run that stops after the pull, such as a boot failure, still records every image's commit |
| `provenance.images[].source` | `runner.json` `images[].source`, for `under_test` images whose label is a `https://github.com/fil-forge/` URL; else null |
| `instrument.fingerprint`, `instrument.box_fingerprint` | computed, below |
| `trace` | constant null until the tracing phase |

The pass summary `rtt`, from one pass of `latency.json`:

| Field | Source |
|---|---|
| `rtt.ok` | the pass's `ok` |
| `rtt.node_to_central_median_ms`, `rtt.central_to_node_median_ms` | the pass's medians of the cross pairs in each direction |
| `rtt.intra_group_max_ms`, `rtt.host_to_ingot_ms` | the pass's values of the same names |
| `rtt.connect_median_max_ms` | the larger of the connects' `connect_median_ms` |

Rates stay in bytes per second as the drill reports them. The page divides by 10^9.

## Classification

A run has drill numbers when its evidence file exists and the drill exited 0 or 1. A run without them is `no_data`, and its record always carries at least one reason: when no rule below gives one, the builder adds `runner_error`. A run with them takes the first class in this order that has a reason in the record: `no_data`, `failed`, `invalid`, `availability_warning`. A run with no reason is `valid`, and since `drill_failure` covers every exit 1 without another reason, a `valid` run always exited 0. A reason found before the drill ran, such as `dirty_start`, stays in the record of a `no_data` run. The two netem exit statuses are handled apart. `netem.sh verify pre` exiting 1, a failed check, does not stop the run: the drill runs, and the record takes `invalid` from the check lines. `netem.sh apply` exiting non-zero, or `verify pre` exiting 2, is a harness error (a service in no group of `config/groups.conf`, a one-shot that did not exit 0, a sidecar that cannot shape): the run stops before the drill, and the record is `no_data` with `runner_error`.

| Class | Mercury and gates |
|---|---|
| `no_data` | no |
| `failed` | no |
| `invalid` | no; numbers shown, not joined to the line |
| `availability_warning` | no; numbers shown and joined to the line |
| `valid` | yes |

If the builder fails, or stops because the run directory belongs to another run, `record.py` writes a minimal record from `runner.json` alone. It is built as for a run whose drill never ran and whose netem passes never ran: class `no_data`; `runner.json`'s reasons plus `record_build_failed`, and `watchdog_timeout` when `watchdog_fired`; `drill_exit` null and no failure codes; `drill.results` and `drill.requests` null; `latency.target_rtt_ms` and `tolerance_pct` from `config/latency.env` with both passes null; the evidence fields of `provenance.harness` null. Image revisions and sources come from `runner.json` as in a full record.

## Triggers

| `trigger.reason` | The runner writes it when |
|---|---|
| `image` | the poll's set has a tracked image digest that differs from `last-started.json` |
| `smelt` | the set's smelt SHA differs and no tracked image digest does |
| `harness` | the set's harness SHA differs and neither a tracked image nor smelt does |
| `nightly` | the 03:00 UTC run starts |
| `campaign` | `campaign.sh --set <file>` starts a run without `--pairing` |
| `pairing` | `campaign.sh --set <file> --pairing <id>` starts a run; `pairing_id` is set |
| `manual` | `run.sh --set <file>` starts a run outside a campaign: acceptance runs, calibration runs, reproducing a failure, and bisecting. It takes its series from `--series` |

`trigger.changed` is filled the same way for every reason, and is empty when nothing moved.

## Reasons

| Reason | Class | Detected from |
|---|---|---|
| `runner_error` | `no_data` | an unexpected runner failure; `netem.sh apply` exited non-zero or a verify pass exited 2; a netem check line that matches no rule; a drill that started without a `verify pre` pass, or has numbers without a `verify post` pass; a drill that started and ended with exit 2 and no evidence, with no exit status, or with any other status, when neither the watchdog nor the runner interrupted it; a `no_data` run that no other rule gives a reason |
| `preflight_failed` | `no_data` | preflight: clock not synchronized, settings file missing, CPU without `sha2` |
| `stack_boot_failed` | `no_data` | `make up` non-zero |
| `setup_failed` | `no_data` | `perf-drill.sh setup` non-zero |
| `harness_build_failed` | `no_data` | `go build` of the drill failed |
| `smelt_unreachable` | `no_data` | `git cat-file -e <sha>^{commit}` failed in the smelt mirror |
| `harness_unreachable` | `no_data` | the same in the storage-qualification mirror |
| `image_pull_failed` | `no_data` | infrastructure: `docker pull` of a pinned digest failed |
| `secrets_unavailable` | `no_data` | infrastructure: reading `/forge-perf/*` from SSM failed |
| `s3_unreachable` | `no_data` | infrastructure: the piri buckets could not be listed or emptied |
| `mirror_fetch_failed` | `no_data` | infrastructure: `git fetch` into a mirror failed |
| `go_module_fetch_failed` | `no_data` | infrastructure: the drill build could not download a module |
| `step_timeout` | `no_data` | a step outran its `timeout` |
| `watchdog_timeout` | `no_data` | the drill step's `timeout` fired (`runner.json` `watchdog_fired`), whatever the exit status. It is the drill step's overrun, the counterpart of `step_timeout` for every other step |
| `drill_interrupted` | `no_data` | `suite.drill_exit` is 2 and the evidence exists, so the drill ran and recorded the interrupt; or the runner interrupted the drill itself, on a stop request or when recovery found the run cut off by a reboot, and wrote the reason to `runner.json`. Exit 2 without evidence is a usage or configuration error (`runner_error`) |
| `no_evidence` | `no_data` | the drill exited 0 or 1 without writing evidence |
| `wrote_nothing` | `no_data` | failure code `wrote_nothing` |
| `record_build_failed` | `no_data` | the builder failed |
| `integrity_failure` | `failed` | evidence `drill.integrity_failures` above 0, or failure code `integrity_failure` |
| `drill_failure` | `failed` | a failure code other than `availability_error`, `read_back_incomplete`, `ingest_cutoff_before_measurement`, `wrote_nothing`, `integrity_failure` and `interrupted`; or drill exit 1 with neither a failure code nor an integrity failure; or drill exit 1 with no other reason |
| `rtt_out_of_band` | `invalid` | a netem round trip or connect outside the band, or no reply |
| `central_ip_changed` | `invalid` | a central container's address changed after apply |
| `netem_missing` | `invalid` | a qdisc, delay or filter missing at verify |
| `container_restarted` | `invalid` | a node or central container restarted, stopped or disappeared after apply; the services go in `outcome.restarted_services` |
| `image_changed` | `invalid` | a container's image ID at the post-check differs from its pinned digest's |
| `harness_mismatch` | `invalid` | evidence `provenance.harness_revision` is empty or differs from `provenance.harness.sha`, or `harness_modified` is true |
| `read_back_incomplete` | `invalid` | failure code `read_back_incomplete`: the duration ended before every scheduled read-back ran |
| `ingest_cutoff_before_measurement` | `invalid` | failure code `ingest_cutoff_before_measurement`: the cap was spent before the first window |
| `no_steady_windows` | `invalid` | evidence without the fact `sustained_windows`, or with 0 |
| `disk_low` | `invalid` | free NVMe space fell under 2 GB during the drill |
| `instrument_modified` | `invalid` | `git status --porcelain` in the forge-perf checkout printed anything, at preflight or at the post-check |
| `dirty_start` | `invalid` | a container, volume, `forge-network` or piri object left from an earlier run |
| `box_type_mismatch` | `invalid` | IMDS instance type differs from the tier's configured type |
| `availability_errors` | `availability_warning` | failure code `availability_error`, or any transport error, 408, 429 or 5xx in `drill.availability`. The import client does not retry, so one error fails a capped run |

The five infrastructure reasons are retried up to three times, 15 minutes apart, and alert only on the third in a row.

`netem.sh` writes its failed checks as lines in each pass's `reasons`. The builder maps them in this order, and the first match wins:

| Line | Reason | Service |
|---|---|---|
| `harness error: …` | `runner_error` | |
| `<svc> restarted after apply …` | `container_restarted` | `<svc>` |
| `<svc> address changed from …` | `central_ip_changed` | |
| `<svc>: container <id> is gone` | `container_restarted` | `<svc>` |
| `<svc> is not running; …` | `container_restarted` | `<svc>` |
| `<svc>: die event after apply` (also `start`, `restart`) | `container_restarted` | `<svc>` |
| `<svc>: cannot read its qdiscs`, `no prio root qdisc`, `netem delay is not …`, `filters do not match …` | `netem_missing` | |
| `no reply from …`, `no TCP connection from …`, `… median round trip … is outside …`, `… is not under …`, `… median connect … is outside …` | `rtt_out_of_band` | |
| `<svc> is <state>` | `container_restarted` | `<svc>` |
| anything else | `runner_error` | |

## Flags

Flags never change the class.

| Flag | Set when |
|---|---|
| `few_windows` | `sustained_windows` under 20, where p5 is the slowest window (`smelt/docs/PERF_TESTING.md:215-216`) |
| `cap_not_reached` | fact `ingest_cutoff_reached` is false: `--duration` ended ingest before the cap. The steady windows still measured the stack |
| `nic_allowance_exceeded` | any `network.allowance_exceeded` counter above 0 |
| `offered_rate_near_median` | the ingest median is at least 90% of `rate_target_bytes_per_s`, so the setting capped the number |
| `superseded` | `runner.json` `superseded` above 0: the run covers several coalesced sets |
| `raw_missing` | `runner.json` `raw_missing`: the private raw tarball is missing. When the tarball is dropped or its upload gives up after the record was built, the runner sets the flag in `runner.json` and rebuilds the record before uploading it; `time.run_finished_at` keeps its first value |

A reviewed PR to `data/overrides.json` citing an issue can reclassify a run. Records are never edited.

## Fingerprints

Both are the SHA-256 of canonical JSON: `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)`, UTF-8. Every input is an integer, string, boolean or null, so float formatting never enters. The checker holds records to that: an integer field written as `4.0` fails, and so does a number too large for a float.

`instrument.fingerprint` hashes:

```
{"forge_perf_instrument_tree": provenance.forge_perf.instrument_tree,
 "smelt_sha": provenance.smelt.sha,
 "harness_sha": provenance.harness.sha,
 "instrument_images": [[repo, digest], ...],
 "settings": drill.settings,
 "target_rtt_us": round(latency.target_rtt_ms * 1000),
 "jitter_us": 0}
```

Every input exists in every record, including the minimal one, so runs on the same instrument share a fingerprint whether or not their drill wrote evidence. The Go toolchain that builds the drill is outside the list for that reason: `provenance.harness.go_version` comes only from the evidence, and `host/versions.env`, which pins Go with `GOTOOLCHAIN=local`, is inside `instrument_tree`.

`instrument_images` lists the `instrument` entries of `provenance.images` in the record's order, which is by `repo`. Under-test digests are outside the fingerprint. `stop_ingest_at_bytes` and `duration_s` are inside, so a nightly run and a per-trigger run have different fingerprints.

`instrument.box_fingerprint` hashes `box.instance_type`, `arch`, `ami_id`, `kernel`, `docker_server`, `docker_compose` and `cpu` under their own names, plus `nvme_model` and `nvme_filesystem`.

`provenance.forge_perf.instrument_tree` is the SHA-256 of `git ls-tree -r --full-tree HEAD` in the box's checkout, with every line whose path starts with a prefix in [`config/not-instrument`](../config/not-instrument) removed. Each line of that file, with surrounding whitespace stripped, is one prefix; blank lines and lines starting with `#` are skipped. The remaining lines keep git's order and each ends in a newline. A new top-level directory counts as instrument until it is listed there.

The publish Action recomputes both fingerprints and rejects a record whose stored values differ. The page marks a run whose fingerprints differ from the previous run on the same box in the same series with the same `stop_ingest_at_bytes` and `duration_s`. Per-trigger and nightly settings alternate within the `calibration` series, and this keeps each compared with its own kind.

## Fixtures

`scripts/host/fixtures/<case>/` holds one case each: a smelt run directory under `run/` in the layout `perf-drill.sh run` writes, `netem/latency.json` (each absent when that step never ran), `runner.json`, and `expected.json`, the record the builder must produce. Every free-text field in them carries the marker `FIXTURE-FREE-TEXT` in place of real drill output, so a test can prove the marker never reaches a record. The cases are a valid run, availability errors, an integrity failure, `wrote_nothing`, `read_back_incomplete`, a restarted container, exit 1 without evidence, exit 2, a stack boot failure with neither a run directory nor a netem pass, and a run whose run directory belongs to another run, which ends in the minimal record. `scripts/host/test_schema.py` checks every `expected.json` against the schema. `scripts/host/test_record.py` builds each case with `record.py` and compares the result with `expected.json` field by field.
