# Calibration

`sets/` holds committed sets, the image digests a campaign or manual run pins ([docs/runner.md](../docs/runner.md)). `workers/`, `noise/` and `falsification/` hold the results of tier calibration ([docs/DESIGN.md §9](../docs/DESIGN.md#9-calibration-and-ceilings)), written by `scripts/operator/calibration-summary.py` from published run records. `ceilings/<date>/<instance type>/` holds the evidence behind each gate on the page, measured by `scripts/operator/calibrate-ceilings.sh` ([docs/operations.md](../docs/operations.md#measuring-the-ceilings)).

## Ceilings

A gate is one instance type's ceiling: the lower of two rates, each measured alone on that type. Both are scored the way the drill scores its ingest rate: 30-second windows over the sustained segment, their p5 (the highest rate at least 95% of the windows held) and their median. Rates are bytes per second, with GB meaning 10^9 bytes.

### S3 PUT

`cmd/s3-ceiling` makes piri's call. It uses minio-go at piri's version (CI fails when the two go.mod files differ), TLS to `s3.us-east-2.amazonaws.com` with no region set, piri's own key, and the box's own `pdp` bucket. Each worker loops `PutObject` of 134,217,728 bytes with default options, from a body that hides `io.Seeker` and `io.ReaderAt` as piri's request body does, onto two keys of its own. The main phase runs 8 workers per vCPU. Half and twice that many follow for 10 minutes each with no pause in between; when twice the workers run more than 3% faster than the main phase, the summary carries `under_driven` and the type is measured again with the higher count.

The instance's network burst allowance would inflate a short measurement. AWS rates m9gd.8xlarge and m9gd.16xlarge as sustained, so their main phase runs 30 minutes and the first 5 are dropped. m9gd.2xlarge has a 4.25 Gbps baseline and bursts to 17 Gbps for a time AWS does not state, so its main phase runs 75 minutes and the last 30 are scored. At minute 60 the burst must have visibly ended: the ENA counter `bw_out_allowance_exceeded` rising in every 10-second sample for 5 minutes, the last 10 minutes' mean rate within 5% of the 10 minutes before, and the last 10 minutes' median window at least 10% below the first 10 minutes'. Otherwise the phase runs to 120 minutes and the summary carries `burst_unconfirmed`. `burst_ended_s` is reported only when the rate fell after it. Failed PUTs still count the bytes read before they failed, so any failure in the scored segment adds the `errors` flag.

### NVMe write

`scripts/host/ceiling-nvme.sh` stops Docker, discards the instance-store drive and writes all of it with fio: O_DIRECT, io_uring, 1 MiB blocks, 4 jobs at queue depth 32, each writing one quarter in order. Writing every byte gets past any cache in the drive. The first 30 seconds are dropped, and scoring ends before the last sample of the first job to finish. A second pass without a discard gives the full-drive rate for reference. Then the drive is formatted and mounted as every boot does it, and the same job writes a file through ext4 for 300 seconds. The file holds 100 GB or 300 seconds at the raw median, whichever is larger, up to 80% of the drive, and fio starts over from its beginning if the time outlasts it. Each job's region is a whole number of MiB, since O_DIRECT needs aligned offsets. If the filesystem rate lands more than 10% below the raw rate, it sets the drive's figure, since ingot's spool writes through the filesystem. A pass too short to score one window stops the measurement.

### Combined

The combined phase runs 10 minutes of S3 PUT while fio writes a file on the drive. It shows how far the two limits interfere on one host and does not set a gate.

## Files

Each `ceilings/<date>/<instance type>/` holds:

| File | Contents |
|---|---|
| `summary.json` | `ceiling`, `limited_by`, and p5, median and windows of `s3_put` and `nvme_write`, with the flags and the `combined` medians |
| `host.json` | instance ID, type, zone, AMI, kernel, vCPUs, ENA driver, fio, Go and minio-go versions, forge-perf commit |
| `s3-put.csv` | one row per second: `t, bytes, objects_done, errors, workers` |
| `s3-put.json` | the S3 scoring: phases with their medians, the sustained segment's start, the second the burst ended |
| `ena.csv` | ENA allowance counters every 10 seconds |
| `nvme-pass1_bw.<job>.log`, `nvme-pass2_bw.<job>.log`, `nvme-fs_bw.<job>.log` | fio bandwidth logs per job, one line per second in KiB/s |
| `nvme-*.json` | fio's reports |
| `nvme.json` | the NVMe scoring of each pass |
| `combined/` | the combined phase's S3 files and fio logs |

## Tier calibration

`scripts/operator/calibration-summary.py` reads the run records of a calibration step and writes its result. It takes every run by ID and never selects runs by time, so the command line in the PR that adds a file reproduces it. Records come from the public results branch, `runs/<yyyy>/<mm>/<run_id>.json`, read with `git show origin/results:<path>` in a forge-perf clone (`git fetch origin results` first; `--ref` names another ref), or from a directory of records given with `--records`. `--out-dir` replaces `calibration/`. Python 3, standard library only.

```
scripts/operator/calibration-summary.py workers --runs <id> <id> ...
scripts/operator/calibration-summary.py noise --series per-trigger --runs <id> ...
scripts/operator/calibration-summary.py noise --series nightly --runs <id> ...
scripts/operator/calibration-summary.py falsification \
  --band calibration/noise/main-per-trigger.json \
  --check older-digest=<id>,<id>,<id> --check cpu-cap=<id>,<id>,<id>
```

A file holds the run IDs, each run's class, reasons, flags, workers, ingest cap, p5 and median, and its forge-perf, smelt and harness SHAs with the digest of every image. It holds nothing else from the records and no time of its own making, so the same runs always give the same bytes. Rates are bytes per second. A falsification check name is lowercase letters, digits and hyphens.

| File | Contents |
|---|---|
| `workers/<date>-<instance type>.json` | per workers value, its runs, mean p5 and mean median; `winner`, the smallest value whose mean p5 and mean median are both within 5% (`margin`) of the best qualified means. A value with any run not `valid`, or with `availability_errors` among its reasons, is disqualified and names those runs. The date is the latest run's start. |
| `noise/<box>-<series>.json` | count, mean, min, max, sample standard deviation and coefficient of variation of p5 and of median; `pass` when the p5 coefficient of variation is at most 10% (`max_cv`). Every run must be `valid` and share one box, instance type, workers value and ingest cap. |
| `falsification/<date>.json` | the band's box, series, run IDs and minimum p5; per check, each run's p5 and flags, how many landed below the band's minimum p5, and `pass` when all of them did. `pass` at the top needs every check to pass. The date is the latest run's start. |
