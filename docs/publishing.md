# Publishing

The box writes run records to a private bucket. `.github/workflows/publish.yml` moves them to the public `results` branch, posts alerts to `#filone-alerts` and deploys the page. [DESIGN.md §7](DESIGN.md#7-results-and-the-page) gives the context and [record.md](record.md) defines the record.

```
box ──► s3://forge-perf-results-654654381893/published/<box>/<run_id>.json   one record per run
    └─► s3://forge-perf-results-654654381893/published/<box>/heartbeat.json  written by every poll
publish.yml, at minutes 7, 22, 37 and 52, one run at a time
    ingest  (role forge-perf-ci-results)  check, commit to results, post alerts
    deploy  (environment github-pages)    build _site from site/, data/ and results; deploy Pages
```

A push to main that touches the site, the schemas, `data/` or these scripts also runs the workflow. Runs share the concurrency group `publish` without cancelling, so a second run waits for the first to finish its commit.

## The results branch

`results` is an orphan branch that no person edits. A repository ruleset blocks force pushes and deletion on it; the workflow's token pushes fast-forward commits.

| Path | Holds |
|---|---|
| `runs/<yyyy>/<mm>/<run_id>.json` | one record per run, written once: sorted keys, two-space indent, trailing newline. The month is the run ID's |
| `status/<box>.json` | alert state for one box: `alerted_classes`, `infra_streak`, `conditions` |
| `status/rejected.json` | bucket keys that failed a check, with the check's name |

Anyone can read every record with `git clone -b results https://github.com/fil-forge/forge-perf.git`.

## Ingest checks

`scripts/publish/ingest.py` lists `published/`, skips every key that is not `published/<box>/<run_id>.json` (heartbeats, the role probe) and every run ID already under `runs/`, and runs each new record through these checks in order, oldest run ID first and at most 200 new keys per run, so a backlog commits over several runs. The first failure rejects the record and names the check; the log gives the key and the check, never the record's text.

| Check | Rejects |
|---|---|
| `key` | a key that is not `published/<box.id>/<run_id>.json` for the record's own `box.id` and `run_id` |
| `size` | a record over 64 KiB |
| `denylist` | a record whose bytes match a line of `PUBLIC_DENYLIST_REGEX` (extended regular expressions, case-insensitive, through `grep -E`, as `scripts/ci/check-denylist.sh`). With no pattern set, ingest publishes nothing and exits 2 |
| `json` | anything but one JSON object; duplicate fields, `NaN` and `Infinity` |
| `denylist` | a record whose committed form (keys sorted, escapes decoded) matches the denylist, which catches a term written as JSON `\u` escapes |
| `schema_unavailable` | a record whose schema cannot be read or uses a keyword `schemacheck.py` does not implement |
| `schema` | a record that fails `schema/run-record.v1.json` as of `provenance.forge_perf.sha` when that commit is an ancestor of main, and as of main otherwise |
| `time` | a start time, finish time or run ID time that matches its pattern but is not a date, such as 30 February |
| `run_id_time` | a run ID whose timestamp is not `time.run_started_at` to the second |
| `future_run_id` | a run ID more than 10 minutes ahead of the time S3 stored the record, or of the workflow's clock when that is earlier. The upload time does not change, so the rejection holds on every run |
| `finished_before_started` | `time.run_finished_at` before `time.run_started_at` |
| `p5_above_median` | an ingest p5 above the ingest median, when both are numbers |
| `valid_inconsistent` | class `valid` with a drill exit other than 0, any reason, or null results or requests |
| `fingerprint` | `instrument.fingerprint` or `instrument.box_fingerprint` that does not recompute by record.md's recipe |
| `internal` | a record that makes a check raise an unexpected error; the log gives the key and the error's type, so one object never stops the others |

Records that pass are committed even when another record in the same run is rejected. A rejection fails the workflow run and posts one Slack line the first time a key fails a given check; the key is checked again on every run, and a key that later passes leaves `status/rejected.json`. The box cannot overwrite a record, so a rejected record stays rejected until someone with bucket access removes it or `published/` expires it after 90 days.

The schema check uses `scripts/host/schemacheck.py`, the checker the box and CI use, so all three apply the same rules with the standard library alone.

`ingest.py --self-test` runs the cases in `scripts/publish/fixtures/cases.json` against a scratch repository holding two schema commits: the valid record is accepted, and records with an unknown field, a denied term (plain and behind a JSON escape), an impossible date, a run ID from the future, a field the record's own schema commit lacks, and each other check's failure are rejected.

## Alerts

The workflow posts to `#filone-alerts` with `SLACK_BOT_TOKEN`. The text comes from public record fields only: box, run ID, class, reasons, restarted services, failure codes, the components in `trigger.changed` with GitHub compare links against the box's previous record (the harness SHA as plain text), and the page link. All lines from one workflow run go in one message.

**Records.** New records are taken per box in run ID order. `calibration` runs never alert and leave the alert state alone.

| Class | Posts when |
|---|---|
| `no_data` | always, except when every reason is an infrastructure reason (`image_pull_failed`, `secrets_unavailable`, `s3_unreachable`, `mirror_fetch_failed`, `go_module_fetch_failed`): then only on the third such record in a row |
| `failed` | a reason is `integrity_failure` |
| `invalid` | a reason is `rtt_out_of_band`, `central_ip_changed`, `netem_missing` or `container_restarted`, or a box or instrument fault an operator has to clear: `disk_low`, `dirty_start`, `image_changed`, `instrument_modified` or `box_type_mismatch` |
| `availability_warning`, `valid` | never, except one line saying the box recovered when a class had alerted |

Each class posts once per box and is added to `alerted_classes`. A `valid` or `availability_warning` record clears the list with the recovery line, and the classes can post again.

**Heartbeats.** For each box in `data/boxes.json` the workflow reads `published/<box>/heartbeat.json` and posts once when a condition starts. A condition that ends leaves `conditions` without a message, so it can post again if it returns.

| Condition | Holds when |
|---|---|
| `heartbeat_stale` | no heartbeat, or its `at` is more than 30 minutes old |
| `poll_failures` | `poll_failures` is 6 or more |
| `long_run` | `state` is `running` and `run_started_at` is more than 7 hours old |
| `no_record` | the box's newest committed run started more than 26 hours ago, or it has none. While a heartbeat under 30 minutes old says `running`, a box with records is judged when that run ends, and a `no_record` already raised holds without posting again |

The Slack post comes before the commit to `results`, and a failed post fails the job. Nothing is committed and the next run posts again, so an alert can repeat but is never lost. While Slack refuses posts, for example with the token unset or the app not in the channel, no new record is committed and records wait in the bucket.

**Publish failures.** Any other failure of the ingest job (the role, S3, an exception or the commit) posts `forge-perf: publish failed` with a link to the workflow run. The deploy job runs only when ingest reached its commit, including after a rejection, so while ingest fails the page keeps its last build and its "Last published" time ages.

## The site build

`scripts/publish/build-site.py` copies `site/`, copies each record to `_site/data/runs/<run_id>.json`, and writes `_site/data/index.json`:

| Field | Holds |
|---|---|
| `published_at` | the build's UTC time, so the page can show when it was last published. A build follows only an ingest that reached its commit, so the time ages while ingest fails or the schedule is disabled. GitHub disables a public repository's scheduled workflows after 60 days without activity |
| `runs` | one row per run in start order: run ID, series, box id, tier and type, start time, class, reasons, flags, p5, median, writes per second, steady windows, measured node-to-central round trip, both fingerprints, and `instrument_changes` |
| `gates`, `overrides` | `data/gates.json` (null while absent) and `data/overrides.json` |
| `heartbeats` | per box, the heartbeat's `at`, `state`, `poll_failures` and `run_started_at` after the ingest job checked each against its pattern, or null |

`instrument_changes` lists what differs from the previous run of the same series on the same box: `forge-perf` (the instrument tree), `smelt`, `harness`, each instrument image's repository, `settings`, `latency` (the target round trip) and `box` (the box fingerprint). It is null for a series' first run.

### Publishing a local run

A local run ([runner.md](runner.md#local-run)) uploads its record to the `local-results` bucket of the local MinIO. With the same `AWS_ENDPOINT_URL` and key exported, the workflow's two steps run against it from a forge-perf checkout, with a scratch directory standing in for the `results` branch:

```sh
mkdir -p local/results
DENYLIST_FILE=/path/to/denylist.regex \
  python3 scripts/publish/ingest.py --bucket local-results --results local/results
python3 scripts/publish/build-site.py --site site --data data --results local/results \
  --out local/_site --heartbeats '{"main":null}'
python3 -m http.server 8000 --bind 127.0.0.1 -d local/_site
```

Ingest applies every check and writes `runs/` and `status/` as in the workflow, and prints the alerts it would post instead of posting them. `data/boxes.json` lists only `main`, so it also prints the missing-heartbeat and no-record alerts for that box. The records are series `calibration`, as every run is while `config/launch.conf` has `SERIES_LIVE=0` and as a manual `--set` run is by default, so the page lists them without counting them.

## Responding to publish alerts

| Alert or sign | Cause and response |
|---|---|
| `forge-perf: publish failed` | Read the linked run's log. The usual causes are a revoked or missing `SLACK_BOT_TOKEN`, a changed trust on `forge-perf-ci-results`, and an unset `PUBLIC_DENYLIST_REGEX` (ingest exits 2). The next scheduled run retries once the cause is fixed. |
| "Last published" hours old and no alert | The alert post itself failed, which points at `SLACK_BOT_TOKEN` first, or the schedule is disabled. `gh workflow list --all` shows `disabled_inactivity` after 60 days without activity in the repository; `gh workflow enable publish.yml` turns it back on. |
| `invalid` with `disk_low` | ingot's spool outgrew the NVMe. Every run of that size repeats it until the size or the box changes. |
| `invalid` with `dirty_start` | The previous wipe left containers, volumes or piri objects. Run `scripts/host/wipe.sh` on the box, and read the previous run's journal for why its wipe did not finish. |
| `invalid` with `image_changed` | A container ran an image other than its pinned digest. Check `config/images.tracked` and what pulled or retagged the image. |
| `invalid` with `instrument_modified` | The box's forge-perf checkout has local edits. Read `git status` there and restore the checkout. |
| `invalid` with `box_type_mismatch` | The instance type differs from the tier's configured type. Compare `config/settings/<instance type>.env` and the box's configuration with the running instance. |

## Overrides

`data/overrides.json` is a list of `{run_id, class, issue}` objects checked against `schema/overrides.v1.json`: a reviewed PR citing a fil-forge issue reclassifies a run on the page. Records are never edited.

## Setup

1. Create the `results` branch as an orphan holding a README, and add a repository ruleset on it that blocks force pushes and deletion.
2. Settings, Pages, Source: GitHub Actions.
3. Set the repository secret `SLACK_BOT_TOKEN`, and invite the Slack app to `#filone-alerts`. `PUBLIC_DENYLIST_REGEX` is already set for `check.yml`.
