#!/usr/bin/env bash
# One run of the stack against one set: smelt and harness SHAs and a digest
# for every tracked image (docs/runner.md, "A run").
#
#   run.sh [--set FILE] [--series SERIES] [--workers N] [--size SIZE]
#          [--duration DURATION] [--trace RATIO] [--until STEP]
#
# Without --set it takes the run the poller left in
# $FORGE_PERF_STATE_DIR/pending.json. With --set it runs that set as a manual
# run in SERIES (per-trigger, nightly, campaign or calibration; default
# calibration). While config/launch.conf has SERIES_LIVE=0 every run is
# series calibration. --workers, --size and --duration override the settings
# file. A campaign's pending run can carry CPU caps (campaign.sh --cap), which
# setup applies with `docker update --cpus`; a capped run is series
# calibration. --trace RATIO, a pending run's trace_ratio (campaign.sh --trace)
# or the settings file's TRACE_RATIO, in that order, traces the run: a
# collector runs beside the stack and the services sample RATIO of requests
# (docs/runner.md, "Tracing"). --trace 0, or a pending trace_ratio of "0",
# runs it untraced whatever the settings file says. experiment.sh's run comes
# from $FORGE_PERF_STATE_DIR/pending-experiment.json, taken before pending.json
# while experiment.sh holds experiment.lock: it runs as series experiment with
# the record's experiment block, pins the branch image under its pull request
# tag, and leaves pending.json and last-started.json alone (docs/runner.md,
# "Experiments"). The steps are preflight, checkout, images,
# boot, setup, latency, drill and check; then every run that started, whether a step stopped it or not, is
# collected, recorded, sent to Grafana, uploaded and wiped. --until STEP stops after STEP and
# leaves the stack as it is, with no record.
#
# Exit status: 0 the run was recorded and wiped (whatever its class), it
# reached --until, or another run holds the lock; 1 a step stopped the run, or
# the record or the wipe failed, and runner.json names the reason; 2 the run
# did not start (usage, no settings for this instance type, WORKERS empty, an
# unusable set, a malformed trace ratio); 130 or 143 a stop request, after the record and the wipe.
# A run taken from pending.json that does not start leaves the file as
# pending.json.rejected, so the next poll does not start it again, and an
# experiment's run as pending-experiment.json.rejected.
#
# SC2016: jq and awk programs are single-quoted on purpose. SC2015: `a && b ||
# stop` is intended, since stop exits whichever of a and b failed.
# shellcheck disable=SC2016,SC2015
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

STEPS="preflight checkout images boot setup latency drill check"
from_pending="" pending_file=""
refuse() {
  echo "run.sh: $*" >&2
  if [ -n "$from_pending" ] && [ -e "$pending_file" ]; then
    write_durable "$pending_file.rejected" <"$pending_file"
    rm -f "$pending_file"
    echo "run.sh: moved $(basename "$pending_file") to $(basename "$pending_file").rejected" >&2
  fi
  exit 2
}
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
# ratio_ok RATIO: a trace sampling ratio, a decimal in (0, 1] such as 0.1 or 1,
# with at most six decimal places, the finest ratio record.py accepts.
ratio_ok() { [[ "$1" =~ ^(0\.[0-9]*[1-9][0-9]*|1(\.0+)?)$ ]] && ! [[ "$1" =~ \.[0-9]{7} ]]; }

set_file="" series="" workers="" size="" duration="" until="" trace=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --set) set_file="$2" ;;
    --series) series="$2" ;;
    --workers) workers="$2" ;;
    --size) size="$2" ;;
    --duration) duration="$2" ;;
    --trace) trace="$2" ;;
    --until) until="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -z "$until" ] || grep -qw -- "$until" <<<"$STEPS" || refuse "--until takes one of: $STEPS"
[ -z "$trace" ] || [ "$trace" = 0 ] || ratio_ok "$trace" ||
  refuse "--trace takes a decimal in (0, 1], such as 0.1, or 0 for an untraced run"

runner_init
mkdir -p "$FORGE_PERF_RUNTIME" "$FORGE_PERF_STATE_DIR"
exec 9>"$FORGE_PERF_RUNTIME/run.lock"
if command -v flock >/dev/null; then
  flock -n 9 || { echo "run.sh: another run holds the lock"; exit 0; }
elif host_ops_skipped; then
  echo "flock is not installed here; the run lock is not taken" >&2
else
  die "flock is missing"
fi
export FORGE_PERF_LOCK_HELD=1

cfg="$FORGE_PERF_CHECKOUT/config"
state="$FORGE_PERF_STATE_DIR"
# shellcheck source=../../config/harness.conf
. "$cfg/harness.conf"
# shellcheck source=../../config/smelt.conf
. "$cfg/smelt.conf"
# shellcheck source=../../config/launch.conf
. "$cfg/launch.conf"
# netem.sh reads config/latency.env itself, and with NETEM_LOCAL=1 takes
# RTT_MS, RTT_TOLERANCE_PCT and NET_SUBNET from the environment, so this shell
# reads the file in a subshell and leaves those variables alone.
# shellcheck source=../../config/latency.env
net_subnet="$(. "$cfg/latency.env" && echo "$NET_SUBNET")"
# shellcheck disable=SC2031 # NET_SUBNET here is the environment's
[ "${NETEM_LOCAL:-}" != 1 ] || net_subnet="${NET_SUBNET:-$net_subnet}"
instance_type="$(imds instance-type)"
settings="$cfg/settings/$instance_type.env"
[ -r "$settings" ] || refuse "no settings file for instance type $instance_type ($settings)"
# shellcheck disable=SC1090
. "$settings"

# --- the set, the series and the drill settings -------------------------------

kind=manual superseded=0 pairing=null attempt=0 caps='{}' experiment=null overrides='{}'
if [ -n "$set_file" ]; then
  set_json="$(jq -ce 'objects' "$set_file")" || refuse "$set_file is not a JSON object"
else
  # The poller writes pending.json under poll.lock. Holding it from here
  # until pending.json is taken keeps a poll from writing a newer set that
  # this run would then remove unrun.
  exec 8>"$FORGE_PERF_RUNTIME/poll.lock"
  if command -v flock >/dev/null; then
    flock -w 300 8 || die "a poll has held poll.lock for 5 minutes"
  fi
  # An experiment's run goes first, but only while experiment.sh, which
  # wrote it, still holds experiment.lock; one it left behind is dropped.
  pending_file="$state/pending-experiment.json" from_pending=experiment
  if [ -e "$pending_file" ] && command -v flock >/dev/null &&
    flock -n "$FORGE_PERF_RUNTIME/experiment.lock" true; then
    echo "run.sh: no experiment holds experiment.lock; dropping pending-experiment.json" >&2
    rm -f "$pending_file"
  fi
  [ -e "$pending_file" ] || pending_file="$state/pending.json" from_pending=1
  [ -e "$pending_file" ] || { echo "run.sh: nothing pending"; exit 0; }
  # A hold set while a poll pass was deciding to start this run. campaign.sh
  # runs its own on a held box.
  [ ! -e "$state/hold" ] || [ "$(jq -r '.kind // ""' "$pending_file" 2>/dev/null)" = campaign ] ||
    { echo "run.sh: the box is held; the pending run waits"; exit 0; }
  pending="$(jq -ce 'objects | select(.set | type == "object")' "$pending_file")" ||
    refuse "$(basename "$pending_file") is not a JSON object with a set"
  set_json="$(jq -c '.set' <<<"$pending")"
  kind="$(jq -r '.kind // "trigger"' <<<"$pending")"
  superseded="$(jq '.superseded // 0' <<<"$pending")"
  pairing="$(jq -c '.pairing_id // null' <<<"$pending")"
  attempt="$(jq '.attempt // 0' <<<"$pending")"
  caps="$(jq -ce '.caps // {} | objects | select(all(to_entries[]; (.key | test("^[a-z0-9][a-z0-9-]*$"))
    and (.value | type == "string" and test("^[0-9]+(\\.[0-9]+)?$") and test("[1-9]"))))' <<<"$pending")" ||
    refuse "pending.json has caps that are not {service: positive decimal}"
  # A campaign's own workers, size and duration, unless the command line says.
  for v in workers size duration; do
    [ -n "${!v}" ] || printf -v "$v" '%s' "$(jq -r --arg v "$v" '.[$v] // empty' <<<"$pending")"
  done
  # An experiment's run: its record block and the branch image's provenance,
  # each value in the pattern the record schema gives it.
  if [ "$from_pending" = experiment ]; then
    [ "$(jq -r '.kind' <<<"$pending")" = experiment ] || refuse "pending-experiment.json has kind '$(jq -r '.kind' <<<"$pending")'"
    experiment="$(jq -ce '.experiment | objects | select((keys == ["commit", "pr", "repository", "request_id", "role", "service"])
      and (.request_id | type == "string" and test("^[a-z0-9][a-z0-9-]{0,39}-pr[1-9][0-9]{0,6}-[0-9a-f]{12}-[1-9][0-9]{0,19}$"))
      and (.service | type == "string" and test("^[a-z0-9][a-z0-9-]{0,39}$"))
      and .repository == "fil-forge/" + .service and (.pr | type == "number" and . >= 1 and . == floor)
      and (.commit | type == "string" and test("^[0-9a-f]{40}$")) and (.role == "main" or .role == "branch"))' \
      <<<"$pending")" || refuse "pending-experiment.json has no well-formed experiment block"
    [ "$pairing" = "\"exp-$(jq -r .request_id <<<"$experiment")\"" ] ||
      refuse "pending-experiment.json's pairing_id is not exp-<request_id>"
    overrides="$(jq -ce '.overrides // {} | objects | select(all(to_entries[];
      (.value | keys == ["ref", "revision", "source"]) and (.value.ref | test("^pr-[1-9][0-9]*-[0-9a-f]{7}$"))
      and (.value.revision | test("^[0-9a-f]{40}$"))
      and (.value.source | test("^https://github\\.com/fil-forge/[a-z0-9][a-z0-9-]{0,39}$"))))' <<<"$pending")" ||
      refuse "pending-experiment.json has overrides that are not {ref, revision, source}"
    [ "$(jq -r .role <<<"$experiment")" = branch ] || [ "$overrides" = '{}' ] ||
      refuse "the main run of an experiment takes no overrides"
  fi
  if [ -z "$trace" ]; then
    trace="$(jq -re '.trace_ratio // "" | strings | select(contains("\n") | not)' <<<"$pending")" ||
      refuse "pending.json has a trace_ratio that is not \"0\" or a decimal in (0, 1]"
    [ -z "$trace" ] || [ "$trace" = 0 ] || ratio_ok "$trace" ||
      refuse "pending.json has a trace_ratio that is not \"0\" or a decimal in (0, 1]"
  fi
fi
set_json="$(jq -c --arg smelt "${SMELT_REF:-}" --arg pin "${SQ_PIN:-}" '
  def orempty: if . == "" then null else . end;
  .smelt //= ($smelt | orempty) | .harness.sha //= ($pin | orempty)' <<<"$set_json")" ||
  refuse "the set is not a JSON object"
smelt_sha="$(jq -r '.smelt // ""' <<<"$set_json")"
harness_sha="$(jq -r '.harness.sha // ""' <<<"$set_json")"
[[ "$smelt_sha" =~ ^[0-9a-f]{40}$ ]] || refuse "the set has no 40-hex smelt SHA and config/smelt.conf sets no SMELT_REF"
[[ "$harness_sha" =~ ^[0-9a-f]{40}$ ]] || refuse "the set has no 40-hex harness SHA and config/harness.conf sets no SQ_PIN"

case "$kind" in
  manual) series="${series:-calibration}" ;;
  trigger) series=per-trigger ;;
  nightly) series=nightly ;;
  campaign) series="$(jq -r '.series // "campaign"' <<<"$pending")" ;;
  experiment) [ "$from_pending" = experiment ] || refuse "pending.json has kind experiment"; series=experiment ;;
  *) refuse "pending.json has kind '$kind'" ;;
esac
grep -qxE 'per-trigger|nightly|campaign|calibration|experiment' <<<"$series" || refuse "unknown series '$series'"
[ "$series" != experiment ] || [ "$kind" = experiment ] || refuse "series experiment is for experiment runs only"
# An experiment's run never counts toward the page's gates and mercury, so it
# keeps its series whatever SERIES_LIVE says.
[ "${SERIES_LIVE:-0}" = 1 ] || [ "$kind" = experiment ] || series=calibration
# A capped run is the falsification check: it never lights a gate.
[ "$caps" = '{}' ] || [ "$kind" != experiment ] || refuse "an experiment's run takes no caps"
[ "$caps" = '{}' ] || series=calibration

# A traced run keeps its series; the record says it was traced. A ratio of 0
# from the command line or pending.json turns off the settings file's.
if [ "$trace" = 0 ]; then
  trace=""
else
  trace="${trace:-${TRACE_RATIO:-}}"
  [ -z "$trace" ] || ratio_ok "$trace" || refuse "TRACE_RATIO in $settings is not empty or a decimal in (0, 1]"
fi
WORKERS="${workers:-${WORKERS:-}}"
[[ "$WORKERS" =~ ^[1-9][0-9]*$ ]] || refuse "WORKERS is empty in $settings and no --workers was given"
if [ "$kind" = nightly ]; then
  size="${size:-${NIGHTLY_SIZE:-}}" duration="${duration:-${NIGHTLY_DURATION:-}}"
else
  size="${size:-${TRIGGER_SIZE:-}}" duration="${duration:-${TRIGGER_DURATION:-}}"
fi
settings_json="$(jq -nce --arg manifest "$MANIFEST_NAME" --arg window "${WINDOW:-}" --arg ramp "${RAMP:-}" \
  --arg workers "$WORKERS" --arg duration "${duration:-}" --arg rate "${RATE_TARGET:-}" --arg size "${size:-}" \
  --arg lag_min "${VERIFY_LAG_MIN:-}" --arg lag_max "${VERIFY_LAG_MAX:-}" --arg accounts "${ACCOUNTS:-}" \
  --arg scale "${RESTORE_SCALE:-}" --arg floor "${ENFORCE_FLOOR:-}" --arg progress "${PROGRESS:-}" \
  --arg keep "${KEEP_OBJECTS:-}" '
  def secs: (capture("^(?<n>[0-9]+)(?<u>[smh])$") | (.n | tonumber) * {"s": 1, "m": 60, "h": 3600}[.u]) // null;
  def bytes: (capture("^(?<n>[0-9]+(\\.[0-9]+)?)GB$") | .n | tonumber * 1e9 | round) // null;
  def int: if test("^[1-9][0-9]*$") then tonumber else null end;
  {profile: "import", manifest: $manifest, window_s: ($window | secs), ramp_s: ($ramp | secs),
   workers: ($workers | int), duration_s: ($duration | secs), rate_target_bytes_per_s: ($rate | bytes),
   stop_ingest_at_bytes: ($size | bytes), verify_lag_min_s: ($lag_min | secs),
   verify_lag_max_s: ($lag_max | secs), accounts: ($accounts | int),
   restore_scale_permille: (($scale | tonumber? // null) | if . then . * 1000 | round else null end),
   enforce_floor: ($floor == "true"), progress_s: ($progress | secs), keep_objects: ($keep == "1")}
  | if [.[] | select(. == null)] == [] then . else error("unreadable") end')" ||
  refuse "a drill setting in $settings (or --size/--duration) is malformed"
# Ingot's local blob budget in bytes, or empty for none. Every compose call of
# the run gives ingot that budget or none, never a caller's own.
budget="$(jq -nre --arg budget "${LOCAL_BLOB_BUDGET:-}" '
  if $budget == "" then "" else
    $budget | (capture("^(?<n>[0-9]+(\\.[0-9]+)?)GB$") | .n | tonumber * 1e9 | round) // 0
    | if . > 0 then . else error("unreadable") end end')" ||
  refuse "LOCAL_BLOB_BUDGET in $settings is not empty or a positive size in GB"
if [ -n "$budget" ]; then export INGOT_LOCAL_BLOB_MAX_BYTES="$budget"; else unset INGOT_LOCAL_BLOB_MAX_BYTES; fi

# The pinned images: VARIABLE repo tag digest role, and each exported as
# VARIABLE=repo@digest for every compose call of the run.
# An experiment's branch image keeps its pull request tag as the ref.
pinned=()
while read -r var ref digest; do
  role=instrument tag="${ref##*:}"
  if [ -z "$digest" ]; then
    role=under_test
    digest="$(jq -r --arg ref "$ref" '.images[$ref] // ""' <<<"$set_json")"
    tag="$(jq -r --arg ref "$ref" --arg tag "$tag" '.[$ref].ref // $tag' <<<"$overrides")"
  fi
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || refuse "no digest for $ref in the set or config/images.lock"
  pinned+=("$var ${ref%:*} $tag $digest $role")
  export "$var=${ref%:*}@$digest"
done < <(sed 's/#.*//' "$cfg/images.tracked" | awk 'NF == 2' && sed 's/#.*//' "$cfg/images.lock" | awk 'NF == 3')

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)" started_epoch="$(date +%s)"
run_id="$FORGE_PERF_BOX_ID-$(tr -d ':-' <<<"$started" | tr TZ tz)"
WORK="$FORGE_PERF_WORK" SMELT="$FORGE_PERF_WORK/smelt" SQ="$FORGE_PERF_WORK/storage-qualification"
RUN="$FORGE_PERF_WORK/run" MIRRORS="${FORGE_PERF_MIRRORS:-/var/lib/forge-perf/mirror}"
SSM="${FORGE_PERF_SSM_PATH:-/forge-perf}" SECRETS="$FORGE_PERF_RUNTIME/secrets"
DENYLIST="${FORGE_PERF_DENYLIST_FILE:-$SECRETS/denylist.regex}"
[ -n "${FORGE_PERF_PIRI_BUCKET_PREFIX:-}" ] || refuse "FORGE_PERF_PIRI_BUCKET_PREFIX is not set"
smelt_prefix="${FORGE_PERF_SMELT_BUCKET_PREFIX:-${FORGE_PERF_PIRI_BUCKET_PREFIX%piri-0-}}"

# The host's own AWS calls go to the box's region. smelt's s3-key.sh writes
# the drill's key with `aws configure set`, which lands on tmpfs.
export AWS_REGION="${FORGE_PERF_REGION:-us-east-2}" AWS_CONFIG_FILE="$FORGE_PERF_RUNTIME/aws/config"
export AWS_SHARED_CREDENTIALS_FILE="$FORGE_PERF_RUNTIME/aws/credentials" GIT_TERMINAL_PROMPT=0
export SMELT_WORKSPACE=0 STORAGE_QUALIFICATION_DIR="$SQ" GOWORK=off
export PIRI_INDEXER=off SPRUE_INDEXER_ENDPOINT='' SPRUE_INDEXER_DID=''
# Only a traced run's collector_start sets these; a caller's own would reach
# the services of an untraced run.
unset OTEL_ENDPOINT OTEL_EXPORTER_OTLP_ENDPOINT OTEL_TRACES_SAMPLER_ARG OTEL_RESOURCE_ATTRIBUTES
go_cache="${FORGE_PERF_GO_CACHE-/var/cache/forge-perf/go}"
if [ -n "$go_cache" ]; then
  export GOCACHE="$go_cache/build" GOMODCACHE="$go_cache/mod" GOTOOLCHAIN=local
fi
# smelt's scripts see neither the host's AWS identity, region nor endpoint:
# the drill's profile carries ingot's.
SMELT_ENV=(env -u AWS_REGION -u AWS_DEFAULT_REGION -u AWS_PROFILE -u AWS_ENDPOINT_URL
  -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN)

# --- runner.json, current.json and failures -------------------------------------

# q <command...>: its output, or nothing when it fails.
q() { ( "$@" ) 2>/dev/null || true; }

# Every docker and aws call this shell makes has a minute to answer
# (FORGE_PERF_CALL_TIMEOUT), so a hung daemon or endpoint cannot hold the run
# until the unit's own timeout. An overrun leaves its command in $overran,
# even from a subshell, and the stop that follows becomes step_timeout. The
# pulls, `make` and the wipe run as their own processes under `within`.
overran="$FORGE_PERF_RUNTIME/overran"
rm -f "$overran"
limited() {
  local status=0
  timeout --kill-after=10 "${FORGE_PERF_CALL_TIMEOUT:-60}" "$@" || status=$?
  [ "$status" != 124 ] && [ "$status" != 137 ] || echo "$*" >"$overran"
  return "$status"
}
docker() { limited docker "$@"; }
aws() { limited aws "$@"; }

box_facts() {
  local cpuinfo arch dev="" model="" bytes=""
  cpuinfo="$(q host_read cat "$R/proc/cpuinfo")"
  arch="$(uname -m)"
  [ "$arch" != aarch64 ] || arch=arm64
  host_ops_skipped || dev="$(q instance_store_dev)"
  if [ -n "$dev" ]; then
    model="$(q lsblk -dno MODEL "$dev" | sed 's/ *$//')" bytes="$(q lsblk -bdno SIZE "$dev" | tr -d ' ')"
  fi
  jq -nc --arg id "$FORGE_PERF_BOX_ID" --arg tier "${BOX_TIER:-}" --arg type "$instance_type" --arg arch "$arch" \
    --arg region "$AWS_REGION" --arg az "$(q imds placement/availability-zone)" --arg ami "$(q imds ami-id)" \
    --arg kernel "$(uname -r)" --arg docker "$(q docker version --format '{{.Server.Version}}')" \
    --arg compose "$(q docker compose version --short)" \
    --arg impl "$(awk -F': *' '/^CPU implementer/ { print $2; exit }' <<<"$cpuinfo")" \
    --arg part "$(awk -F': *' '/^CPU part/ { print $2; exit }' <<<"$cpuinfo")" \
    --arg features "$(awk -F': *' '/^(Features|flags)/ { print $2; exit }' <<<"$cpuinfo")" \
    --arg cores "$(q getconf _NPROCESSORS_ONLN)" \
    --arg mem "$(q host_read awk '/^MemTotal/ { print $2 * 1024 }' "$R/proc/meminfo")" \
    --arg model "$model" --arg bytes "$bytes" --arg fs "$(q host_read findmnt -no FSTYPE "$FORGE_PERF_NVME_MOUNT")" \
    --arg skip "$(host_ops_skipped && echo 1)" '
    def n: if . == "" then null else . end;
    def num: if . == "" then null else tonumber end;
    {id: $id, tier: ($tier | num), instance_type: $type, arch: $arch, region: $region,
     availability_zone: ($az | n), ami_id: ($ami | n), kernel: $kernel, docker_server: ($docker | n),
     docker_compose: ($compose | n),
     cpu: {implementer: ($impl | n), part: ($part | n), cores: ($cores | num),
           features: ($features | split(" ") | map(select(. != "")))},
     mem_total_bytes: ($mem | num), nvme: {model: ($model | n), size_bytes: ($bytes | num), filesystem: ($fs | n)}}
    # A laptop has no instance metadata. Placeholders the schema accepts keep
    # a local run recordable; the box ID marks the record as local.
    | if $skip == "1" then .instance_type = "local.large" | .availability_zone = "us-east-2a"
        | .ami_id = "ami-00000000" | .mem_total_bytes //= 0 else . end'
}

# SHA-256 of `git ls-tree -r --full-tree HEAD` without the paths in
# config/not-instrument (docs/record.md, "Fingerprints").
instrument_tree() {
  git -C "$FORGE_PERF_CHECKOUT" ls-tree -r --full-tree HEAD | python3 -c '
import hashlib, sys
prefixes = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
h = hashlib.sha256()
for line in sys.stdin.buffer:
    if not any(line.split(b"\t", 1)[1].decode().startswith(p) for p in prefixes):
        h.update(line)
print(h.hexdigest())' "$cfg/not-instrument"
}

# rj [jq options...] FILTER: update runner.json in the state directory and,
# once it exists, in the run directory.
rj() {
  jq "$@" "$state/runner.json" >"$state/runner.json.tmp"
  mv "$state/runner.json.tmp" "$state/runner.json"
  [ ! -d "$RUN" ] || cp "$state/runner.json" "$RUN/runner.json"
}

set_phase() {
  jq -n --arg id "$run_id" --arg phase "$1" --arg dir "$RUN" '{run_id: $id, phase: $phase, run_dir: $dir}' |
    write_durable "$state/current.json"
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
add_reason() { rj --arg r "$1" '.reasons = (.reasons + [$r] | unique)'; }

# stop REASON MESSAGE: the run cannot go on.
failed=""
stop() {
  local reason="$1" message="$2"
  if [ -s "$overran" ]; then
    message="$(head -c 200 "$overran") ran over ${FORGE_PERF_CALL_TIMEOUT:-60}s; $message" reason=step_timeout
  fi
  echo "run.sh: $reason: $message" >&2
  failed="$reason"
  add_reason "$reason"
  exit 1
}

finish() {
  local status=$?
  trap - EXIT
  set +e
  if [ "$status" -ne 0 ] && [ -z "$failed" ] && [ -z "$stop_requested" ]; then
    add_reason "$([ -s "$overran" ] && echo step_timeout || echo runner_error)"
  fi
  if [ -n "$until" ]; then
    rm -f "$state/current.json"
    if [ "$status" -eq 0 ]; then
      echo "run $run_id: $until done; the stack stays up until scripts/host/wipe.sh"
    else
      echo "run $run_id stopped: $(jq -r '.reasons | join(" ")' "$state/runner.json")" >&2
    fi
    exit "$status"
  fi
  close_out || [ "$status" -ne 0 ] || status=1
  case "$from_pending" in
    experiment) experiment_run ;;
    1) last_run ;;
  esac
  echo "run $run_id: ${record_class:-no record ($(jq -r '.reasons | join(" ")' "$state/runner.json"))}"
  exit "$status"
}

# last_run: what the poller needs to know about a run it dispatched, to
# retry a set an infrastructure failure stopped (docs/runner.md, "Polling").
last_run() {
  jq -n --arg id "$run_id" --arg kind "$kind" --argjson set "$set_json" --argjson superseded "$superseded" \
    --argjson attempt "$attempt" --argjson previous "$last" --slurpfile runner "$state/runner.json" \
    '{run_id: $id, kind: $kind, set: $set, superseded: $superseded, attempt: $attempt,
      previous_started: $previous, reasons: $runner[0].reasons}' | write_durable "$state/last-run.json"
}

# experiment_run: the run's ID and reasons for experiment.sh, which reads its
# record from state/experiment/records/.
experiment_run() {
  mkdir -p "$state/experiment"
  jq -n --arg id "$run_id" --slurpfile runner "$state/runner.json" '{run_id: $id, reasons: $runner[0].reasons}' |
    write_durable "$state/experiment/last-run.json"
}

# within SECONDS REASON COMMAND...: run COMMAND under timeout. An overrun
# stops the run with step_timeout, any other failure with REASON.
within() {
  local secs="$1" reason="$2" status=0
  shift 2
  timeout --kill-after=60 "$secs" "$@" || status=$?
  case "$status" in
    0) ;;
    124 | 137) stop step_timeout "$* ran over ${secs}s" ;;
    *) stop "$reason" "$* exited $status" ;;
  esac
}

# host_require REASON MESSAGE COMMAND...: a fact about the host that must
# hold. Skip mode logs it and goes on.
host_require() {
  local reason="$1" message="$2"
  shift 2
  if host_ops_skipped; then
    echo "host-check skipped: $*" >&2
    return 0
  fi
  "$@" >/dev/null 2>&1 || stop "$reason" "$message"
}

# --- steps ------------------------------------------------------------------------

# dirt: what an earlier run left behind, space-separated, or empty.
find_dirt() {
  local store n
  dirt=""
  [ -z "$(stack_containers)" ] || dirt+=" containers"
  [ -z "$(stack_volumes)" ] || dirt+=" volumes"
  ! docker network inspect forge-network >/dev/null 2>&1 || dirt+=" forge-network"
  for store in $FORGE_PERF_PIRI_STORES; do
    n="$(piri_aws s3api list-objects-v2 --bucket "$FORGE_PERF_PIRI_BUCKET_PREFIX$store" --max-keys 1 \
      --query KeyCount --output text)" || stop s3_unreachable "cannot list bucket $FORGE_PERF_PIRI_BUCKET_PREFIX$store"
    [ "$n" = 0 ] || dirt+=" $store"
  done
  [ ! -s "$overran" ] || stop step_timeout "looking for an earlier run's containers, volumes and network"
}

step_preflight() {
  local modified docker_major unread
  step "preflight"
  host_require preflight_failed "the clock is not synchronized" \
    sh -c '[ "$(timedatectl show -p NTPSynchronized --value)" = yes ]'
  host_require preflight_failed "the CPU lacks sha2, so SHA-256 would run in software" \
    grep -qE '^(Features|flags)[[:space:]]*:(.* )?(sha2|sha_ni)( |$)' "$R/proc/cpuinfo"
  host_require preflight_failed "sch_netem cannot be loaded" modprobe sch_netem
  docker_major="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)"
  [[ "$docker_major" =~ ^[0-9]+$ && "$docker_major" -ge 25 ]] ||
    stop preflight_failed "Docker does not answer, or its engine is older than 25"
  modified="$(git -C "$FORGE_PERF_CHECKOUT" status --porcelain)"
  if [ -n "$modified" ]; then
    if host_ops_skipped && [ "${FORGE_PERF_ALLOW_MODIFIED:-}" = 1 ]; then
      echo "the forge-perf checkout has local changes; allowed in skip mode" >&2
    else
      stop instrument_modified "the forge-perf checkout differs from its commit: $(tr '\n' ' ' <<<"$modified")"
    fi
  fi
  # update.sh records HEAD in updated-rev as its last step. A record for
  # another commit means the checkout moved and provisioning or the unit sync
  # did not finish, so the host may still run the previous pins.
  if [ "${FORGE_PERF_MODE:-persistent}" = persistent ] && [ -s "$state/updated-rev" ] &&
    [ "$(cat "$state/updated-rev")" != "$(git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)" ]; then
    stop preflight_failed "update.sh has not completed for this checkout"
  fi
  [[ "$FORGE_PERF_PIRI_BUCKET_PREFIX" = "${smelt_prefix}piri-0-" ]] ||
    stop runner_error "FORGE_PERF_PIRI_BUCKET_PREFIX must be the smelt bucket prefix followed by piri-0-"
  # The box facts the record schema requires; without them no record, not
  # even the minimal one, could be written. Skip mode has no instance store.
  unread="$(jq -r '.box | {tier, availability_zone, ami_id, docker_server, docker_compose, cores: .cpu.cores,
    mem_total_bytes, nvme_model: .nvme.model, nvme_size_bytes: .nvme.size_bytes, nvme_filesystem: .nvme.filesystem}
    | to_entries | map(select(.value == null) | .key) | join(" ")' "$state/runner.json")"
  if [ -n "$unread" ]; then
    host_ops_skipped && echo "box facts not read in skip mode: $unread" >&2 ||
      stop preflight_failed "cannot read the box facts: $unread"
  fi

  find_dirt
  if [ -n "$dirt" ]; then
    echo "an earlier run left:$dirt; wiping" >&2
    rj '.reasons = (.reasons + ["dirty_start"] | unique)'
    within 1800 runner_error "$here/wipe.sh"
    find_dirt
    [ -z "$dirt" ] || stop runner_error "still left after the wipe:$dirt"
  fi
  mkdir -p "$WORK"
  find "$WORK" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  mkdir -p "$RUN"
  cp "$state/runner.json" "$RUN/runner.json"
  # The fuller facts (Docker's configuration, timers, clock, kernel settings,
  # unpinned package versions) go into the raw tarball; only the subset in
  # runner.json's box enters the record and its fingerprint.
  if ! timeout --kill-after=10 "${FORGE_PERF_CALL_TIMEOUT:-60}" "$here/box-facts.sh" \
    >"$RUN/box-facts.json" 2>"$RUN/box-facts.err"; then
    echo "box-facts.sh failed; the raw tarball has no box-facts.json: $(tail -c 300 "$RUN/box-facts.err")" >&2
    rm -f "$RUN/box-facts.json"
  fi
  rm -f "$RUN/box-facts.err"

  install -d -m 0700 "$SECRETS" "$FORGE_PERF_RUNTIME/aws"
  if [ "${FORGE_PERF_SECRETS:-ssm}" = ssm ]; then
    local id secret
    id="$(ssm_value "${FORGE_PERF_PIRI_KEY_ID_PARAM:-$SSM/piri-s3-access-key-id}")" &&
      secret="$(ssm_value "${FORGE_PERF_PIRI_SECRET_PARAM:-$SSM/piri-s3-secret-access-key}")" ||
      stop secrets_unavailable "cannot read piri's S3 key from SSM"
    (umask 077 && printf 'FORGE_PERF_PIRI_S3_KEY_ID=%s\nFORGE_PERF_PIRI_S3_SECRET=%s\n' "$id" "$secret" \
      >"$FORGE_PERF_PIRI_S3_CREDENTIALS")
  fi
  [ -r "$FORGE_PERF_PIRI_S3_CREDENTIALS" ] || stop secrets_unavailable "no $FORGE_PERF_PIRI_S3_CREDENTIALS"
  # shellcheck disable=SC1090
  . "$FORGE_PERF_PIRI_S3_CREDENTIALS"
  export SMELT_PIRI_S3_ACCESS_KEY_ID="${FORGE_PERF_PIRI_S3_KEY_ID:-}"
  export SMELT_PIRI_S3_SECRET_ACCESS_KEY="${FORGE_PERF_PIRI_S3_SECRET:-}"
  [ -n "$SMELT_PIRI_S3_ACCESS_KEY_ID" ] && [ -n "$SMELT_PIRI_S3_SECRET_ACCESS_KEY" ] ||
    stop secrets_unavailable "piri's S3 key is empty"
  # The record is checked against the denylist; a run that cannot be
  # recorded does not start.
  [ -n "$until" ] || get_denylist || stop secrets_unavailable "no denylist at $DENYLIST, or SSM did not answer"
}

# get_denylist: FORGE_PERF_DENYLIST_FILE, or the SSM parameter on tmpfs.
get_denylist() {
  [ ! -s "$DENYLIST" ] || return 0
  [ "${FORGE_PERF_SECRETS:-ssm}" = ssm ] && [ -z "${FORGE_PERF_DENYLIST_FILE:-}" ] || return 1
  mkdir -p "$SECRETS"
  (umask 077 && ssm_value "${FORGE_PERF_DENYLIST_PARAM:-$SSM/denylist}" >"$DENYLIST.tmp") &&
    mv "$DENYLIST.tmp" "$DENYLIST"
}

# mirror NAME URL SHA REASON EXTRA GIT...: fetch every branch into the bare
# mirror, then require SHA. EXTRA is the ref namespace that keeps a pinned
# commit reachable after its branch is gone: `pull` (pull request heads, for
# the private harness, whose pinned commit heads an open pull request) or
# `tags` (for public smelt, where anyone can open a pull request and its head
# would land on the root volume; forge-perf tags each smelt commit it pins). A
# mirror without `pull` drops any pull request refs an earlier fetch left. A
# failed fetch only stops the run when the commit is not already there.
mirror() {
  local name="$1" url="$2" sha="$3" reason="$4" extra="$5" dir="$MIRRORS/$1.git"
  shift 5
  [ -d "$dir" ] || git init -q --bare "$dir"
  git -C "$dir" config remote.origin.url "$url"
  git -C "$dir" config --replace-all remote.origin.fetch '+refs/heads/*:refs/heads/*'
  case "$extra" in
    pull) git -C "$dir" config --add remote.origin.fetch '+refs/pull/*/head:refs/pull/*/head' ;;
    tags)
      git -C "$dir" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
      git -C "$dir" for-each-ref --format='delete %(refname)' refs/pull | git -C "$dir" update-ref --stdin
      ;;
    *) stop runner_error "mirror $name: unknown ref namespace $extra" ;;
  esac
  if ! timeout --kill-after=60 600 "$@" -C "$dir" fetch --prune --quiet origin; then
    git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null ||
      stop mirror_fetch_failed "cannot fetch $name from $url"
    echo "fetching $name failed; $sha is already in the mirror" >&2
  fi
  git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null || stop "$reason" "$name has no commit $sha"
}

step_checkout() {
  local knob
  step "checkout"
  mkdir -p "$MIRRORS"
  harness_git "$SECRETS" || case $? in
    2) stop runner_error "the harness credential (SQ_AUTH) must be deploy-key, app or none" ;;
    *) case "${FORGE_PERF_HARNESS_AUTH:-${SQ_AUTH:-app}}" in
         app) stop secrets_unavailable "cannot mint a harness token from the GitHub App key in SSM" ;;
         *) stop secrets_unavailable "cannot read the harness deploy key from SSM" ;;
       esac ;;
  esac
  mirror smelt "${FORGE_PERF_SMELT_URL:-https://github.com/$SMELT_REPO.git}" "$smelt_sha" smelt_unreachable tags git
  mirror storage-qualification "$HARNESS_URL" "$harness_sha" harness_unreachable pull "${HARNESS_GIT[@]}"
  git clone -q --no-checkout "$MIRRORS/smelt.git" "$SMELT" &&
    git -C "$SMELT" checkout -q --detach "$smelt_sha" || stop runner_error "cannot check out smelt $smelt_sha"
  git clone -q --no-checkout "$MIRRORS/storage-qualification.git" "$SQ" &&
    git -C "$SQ" checkout -q --detach "$harness_sha" || stop runner_error "cannot check out the harness $harness_sha"
  # The smelt settings a run depends on; an older smelt would run another stack.
  for knob in KEEP_OBJECTS DISK_FACTOR PERF_EXTRA_METADATA; do
    grep -q "$knob" "$SMELT/scripts/perf-drill.sh" || stop runner_error "smelt $smelt_sha has no $knob in perf-drill.sh"
  done
  grep -q PIRI_INDEXER "$SMELT/systems/piri/entrypoint.sh" || stop runner_error "smelt $smelt_sha has no PIRI_INDEXER"
  # An older smelt would run ingot without the budget the record names.
  [ -z "$budget" ] || grep -q INGOT_LOCAL_BLOB_MAX_BYTES "$SMELT/systems/ingot/compose.yml" ||
    stop runner_error "smelt $smelt_sha does not pass INGOT_LOCAL_BLOB_MAX_BYTES to ingot"
  within 900 go_module_fetch_failed go -C "$SQ" mod download
  within 900 harness_build_failed go -C "$SQ" build -o bin/drill ./cmd/drill
}

step_images() {
  local listed bad refs line
  step "images"
  [[ "$FORGE_PERF_PIRI_S3_ENDPOINT" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ && "$smelt_prefix" =~ ^[a-z0-9][a-z0-9.-]*$ &&
    "$FORGE_PERF_PIRI_S3_INSECURE" =~ ^(true|false)$ ]] || stop runner_error "piri's S3 endpoint, prefix or insecure flag is malformed"
  sed -e "s|@ENDPOINT@|$FORGE_PERF_PIRI_S3_ENDPOINT|" -e "s|@BUCKET_PREFIX@|$smelt_prefix|" \
    -e "s|@INSECURE@|$FORGE_PERF_PIRI_S3_INSECURE|" "$cfg/smelt-manifest.yml.tmpl" >"$RUN/smelt-manifest.yml"
  export SMELT_MANIFEST="$RUN/smelt-manifest.yml"
  within 600 runner_error "${SMELT_ENV[@]}" make -C "$SMELT" generate

  refs="$(for line in "${pinned[@]}"; do awk '{ print $2 "@" $4 }' <<<"$line"; done)"
  listed="$(cd "$SMELT" && limited "${SMELT_ENV[@]}" docker compose config --images)" ||
    stop runner_error "docker compose config failed"
  bad="$(grep -vxF -f <(printf '%s\n' "$refs") <<<"$listed" || true)"
  [ -z "$bad" ] || stop runner_error "images outside the pinned set: $(tr '\n' ' ' <<<"$bad")"

  # The interpolated model would carry piri's key, so this call runs without
  # it and only each service's image and piri's S3 target reach the disk.
  (cd "$SMELT" && limited "${SMELT_ENV[@]}" -u SMELT_PIRI_S3_ACCESS_KEY_ID -u SMELT_PIRI_S3_SECRET_ACCESS_KEY \
    docker compose config --format json) |
    jq '{services: (.services | map_values({image})),
         piri_s3: (.services["piri-0"].environment // {} | {PIRI_S3_ENDPOINT, PIRI_S3_BUCKET_PREFIX})}' \
      >"$RUN/compose-images.json" || stop runner_error "docker compose config failed"
  # A smelt without the manifest's storage.s3 drops it and runs piri against
  # an in-stack MinIO, which would measure another topology.
  jq -e --arg e "$FORGE_PERF_PIRI_S3_ENDPOINT" --arg p "$FORGE_PERF_PIRI_BUCKET_PREFIX" \
    '.piri_s3 == {PIRI_S3_ENDPOINT: $e, PIRI_S3_BUCKET_PREFIX: $p} and (.services | has("piri-minio") | not)' \
    "$RUN/compose-images.json" >/dev/null ||
    stop runner_error "smelt $smelt_sha does not point piri-0 at $FORGE_PERF_PIRI_S3_ENDPOINT/$FORGE_PERF_PIRI_BUCKET_PREFIX*"
  rj --slurpfile c "$RUN/compose-images.json" --arg trace "$trace" '.images |= map(. as $i | .services =
    if $i.variable == "NETSHOOT_IMAGE" then ["netem"]
    elif $i.variable == "OTEL_COLLECTOR_IMAGE" then (if $trace == "" then [] else ["otel-collector"] end)
    else [$c[0].services | to_entries[] | select(.value.image == $i.repo + "@" + $i.digest) | .key] | sort end)'

  printf '%s\n' "${pinned[@]}" | awk '{ print $1, $2 ":" $3, $4 }' >"$state/images.pinned"
  : >"$RUN/pull.list"
  while read -r line; do
    docker image inspect "$line" >/dev/null 2>&1 || echo "$line" >>"$RUN/pull.list"
  done <<<"$refs"
  if [ -s "$RUN/pull.list" ]; then
    within 1200 image_pull_failed xargs -P4 -n1 docker pull --quiet <"$RUN/pull.list"
  fi

  # Each image's commit and repository, from its OCI labels, so a run that
  # stops after this step still records what it would have measured.
  local labels='{}' got ref
  for ref in $refs; do
    got="$(docker image inspect --format '{{json .Config.Labels}}' "$ref")" ||
      stop image_pull_failed "$ref is not present after the pull"
    labels="$(jq -c --arg r "$ref" --argjson l "$got" '.[$r] = {
      revision: (($l // {})["org.opencontainers.image.revision"] // null),
      source: (($l // {})["org.opencontainers.image.source"] // null)}' <<<"$labels")" ||
      stop runner_error "unreadable labels on $ref"
  done
  rj --argjson l "$labels" '.images |= map(. + $l[.repo + "@" + .digest])'
  # An experiment's branch image: the requested commit and repository, which
  # its labels, set by the same workflow, should repeat.
  rj --argjson o "$overrides" '.images |= map(. as $i | ([$o | to_entries[] | select(.key | startswith($i.repo + ":"))
    | .value][0]) as $v | if $v then $i + {revision: $v.revision, source: $v.source} else $i end)'
}

step_boot() {
  step "boot"
  set_phase boot
  docker network create --driver bridge --subnet "$net_subnet" forge-network >/dev/null ||
    stop stack_boot_failed "cannot create forge-network on $net_subnet"
  [ -z "$trace" ] || collector_start
  within 900 stack_boot_failed "${SMELT_ENV[@]}" make -C "$SMELT" up
  if [ -n "$trace" ]; then
    [ "$(docker inspect -f '{{.State.Running}}' "$collector" 2>/dev/null)" = true ] ||
      stop stack_boot_failed "the trace collector stopped while the stack booted; its log is in traces/collector.log"
  fi
  rj --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.time.stack_up_at = $t'
}

# collector_start: the trace collector on forge-network under the alias
# otel-collector, writing into $RUN/traces, and the variables smelt passes to
# the services. It is not a smelt service, so netem never delays it. smelt
# reads the endpoint as OTEL_ENDPOINT and hands it to the services as
# OTEL_EXPORTER_OTLP_ENDPOINT; both are set.
collector=forge-perf-otel
collector_start() {
  mkdir -p "$RUN/traces"
  # The image runs as 10001 (its Config.User). A laptop's user cannot chown.
  chown 10001:10001 "$RUN/traces" 2>/dev/null || chmod 0777 "$RUN/traces"
  docker run -d --name "$collector" --network forge-network --network-alias otel-collector \
    --cpus 2 --memory 2g -e "FORGE_PERF_RUN_ID=$run_id" -v "$RUN/traces:/traces" \
    -v "$cfg/otel-collector.yaml:/etc/forge-perf/otel-collector.yaml:ro" \
    "$OTEL_COLLECTOR_IMAGE" --config /etc/forge-perf/otel-collector.yaml >/dev/null ||
    stop stack_boot_failed "cannot start the trace collector"
  export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 OTEL_ENDPOINT=http://otel-collector:4318
  export OTEL_TRACES_SAMPLER_ARG="$trace" OTEL_RESOURCE_ATTRIBUTES="forge_perf.run_id=$run_id"
}

# collector_close: after the drill, before collect. The services export
# their last batches within seconds (the SDKs' default delay is 5 s), so it
# waits, scrapes the collector's counters from a container on forge-network,
# stops it with a minute to flush and close traces.jsonl, keeps its log and
# removes it. Each part is best effort; the record reads what is there.
collector_close() {
  [ -n "$trace" ] && [ -d "$RUN/traces" ] && docker inspect "$collector" >/dev/null 2>&1 || return 0
  step "traces"
  sleep "${FORGE_PERF_TRACE_SETTLE_S:-10}"
  docker run --rm --network forge-network "$NETSHOOT_IMAGE" \
    curl -sf --max-time 20 http://otel-collector:8888/metrics >"$RUN/traces/collector-metrics.txt" ||
    { echo "run.sh: cannot scrape the trace collector's metrics" >&2; rm -f "$RUN/traces/collector-metrics.txt"; }
  timeout --kill-after=10 90 docker stop -t 60 "$collector" >/dev/null ||
    echo "run.sh: the trace collector did not stop cleanly; traces.jsonl may end in a partial line" >&2
  docker logs "$collector" >"$RUN/traces/collector.log" 2>&1 || echo "run.sh: no trace collector log" >&2
  docker rm -f "$collector" >/dev/null || echo "run.sh: the wipe removes the trace collector" >&2
}

step_setup() {
  local ingot ip
  step "setup"
  case "${FORGE_PERF_CLIENT_PATH:-container-ip}" in
    container-ip)
      # Straight to ingot's bridge address, past Docker's userland proxy. No
      # ":80": the drill's S3 client signs the Host header as it sends it,
      # hilt checks SigV4 against the host with the scheme's default port
      # stripped, and "<ip>:80" fails every drill request with 403
      # SignatureDoesNotMatch.
      ingot="$(cd "$SMELT" && docker compose ps -q ingot)" || stop setup_failed "no ingot container"
      ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "forge-network"}}{{.IPAddress}}{{end}}' "$ingot")" ||
        stop setup_failed "cannot read ingot's forge-network address"
      [ -n "$ip" ] || stop setup_failed "ingot has no forge-network address"
      export INGOT_URL="http://$ip"
      ;;
    published) unset INGOT_URL ;;
    *) stop runner_error "FORGE_PERF_CLIENT_PATH must be container-ip or published" ;;
  esac
  within 600 setup_failed "${SMELT_ENV[@]}" "$SMELT/scripts/perf-drill.sh" setup
  apply_caps
}

# apply_caps: each capped service's container to its CPUs, checked through
# HostConfig.NanoCpus. `docker update` restarts nothing, and netem.sh apply
# records start times and addresses after it, so verify post sees no change.
apply_caps() {
  local svc cpus cid nano want
  while read -r svc cpus; do
    [ -n "$svc" ] || continue
    cid="$(cd "$SMELT" && docker compose ps -q "$svc")" && [ -n "$cid" ] || stop runner_error "no $svc container to cap"
    docker update --cpus "$cpus" "$cid" >/dev/null || stop runner_error "docker update --cpus $cpus failed for $svc"
    nano="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$cid")" || stop runner_error "cannot read $svc's CPU cap"
    want="$(awk -v c="$cpus" 'BEGIN { printf "%.0f", c * 1e9 }')"
    [ "$nano" = "$want" ] || stop runner_error "$svc has NanoCpus $nano after the update, not $want"
    echo "capped $svc at $cpus CPUs"
  done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"$caps")
}

step_latency() {
  local status=0
  step "latency"
  export NETEM_DIR="$RUN/netem"
  within 300 runner_error "$here/netem.sh" apply
  # A failed check (1) does not stop the run: the record reads it from
  # latency.json and the run is invalid. 2 is a harness error.
  timeout --kill-after=60 300 "$here/netem.sh" verify pre || status=$?
  case "$status" in
    0 | 1) ;;
    124 | 137) stop step_timeout "netem.sh verify pre ran over 300s" ;;
    *) stop runner_error "netem.sh verify pre exited $status" ;;
  esac
}

# io_line: one row of io.csv. The epoch; the instance store's cumulative
# sectors read and written and milliseconds busy (fields 6, 10 and 13 of
# /proc/diskstats); the cumulative user, nice, system, idle, iowait, irq,
# softirq and steal jiffies of /proc/stat's cpu line; and Dirty and Writeback
# from /proc/meminfo in kB. A source that cannot be read gives "-" fields, so
# every row has 14. Raw evidence only: the record does not read it.
io_line() {
  local d c m
  d="$(awk -v dev="$io_dev" 'dev != "" && $3 == dev { print $6, $10, $13 }' "$R/proc/diskstats" 2>/dev/null)"
  c="$(awk '$1 == "cpu" { print $2, $3, $4, $5, $6, $7, $8, $9 }' "$R/proc/stat" 2>/dev/null)"
  m="$(awk '/^Dirty:/ { d = $2 } /^Writeback:/ { w = $2 } END { if (d != "") print d, w + 0 }' "$R/proc/meminfo" 2>/dev/null)"
  echo "$(date +%s) ${d:-- - -} ${c:-- - - - - - - -} ${m:-- -}" >>"$RUN/io.csv"
}

# sample: in the background during the drill, the primary interface's
# transmitted bytes and an io.csv row every second, and the NVMe's free space
# every 30 seconds.
sample() {
  local n=0 tx free
  while :; do
    if [ -n "$nic_if" ] && tx="$(cat "$R/sys/class/net/$nic_if/statistics/tx_bytes" 2>/dev/null)"; then
      echo "$(date +%s) $tx" >>"$RUN/nic.csv"
    fi
    io_line
    if [ $((n % 30)) -eq 0 ] && ! host_ops_skipped; then
      free="$(df -Pk "$FORGE_PERF_NVME_MOUNT" 2>/dev/null | awk 'NR == 2 { print $4 * 1024 }')"
      if [[ "$free" =~ ^[0-9]+$ ]]; then
        echo "$(now) $free" >>"$RUN/disk.csv"
        [ "$free" -ge 2000000000 ] || : >"$RUN/disk-low"
      fi
    fi
    n=$((n + 1))
    sleep 1
  done
}

# The ENA allowance counters' deltas (all five, or null), and the median
# egress rate and the seconds above the type's baseline from the samples.
nic_facts() {
  jq -n --rawfile pre "$RUN/ethtool-pre.txt" --rawfile post "$RUN/ethtool-post.txt" \
    --rawfile samples "$RUN/nic.csv" --arg baseline "${BASELINE_BYTES_PER_S:-}" '
    def counters: [scan("(?<k>[a-z_]+)_allowance_exceeded: *(?<v>[0-9]+)") | {(.[0]): (.[1] | tonumber)}] | add // {};
    def keys5: ["bw_in", "bw_out", "pps", "conntrack", "linklocal"];
    ($pre | counters) as $a | ($post | counters) as $b |
    ($samples | split("\n") | map(select(test("^[0-9]+ [0-9]+$")) | split(" ") | map(tonumber))) as $s |
    [range(1; $s | length) | select($s[.][0] > $s[. - 1][0] and $s[.][1] >= $s[. - 1][1]) |
     {dt: ($s[.][0] - $s[. - 1][0]), rate: (($s[.][1] - $s[. - 1][1]) / ($s[.][0] - $s[. - 1][0]))}] as $r |
    ($r | map(.rate) | sort) as $sorted |
    {allowance_exceeded: (if all(keys5[]; $a[.] != null and $b[.] != null)
       then [keys5[] | {(.): ($b[.] - $a[.])}] | add else null end),
     egress_bytes_per_s_median: (if $sorted == [] then null
       else ($sorted | if length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end)
       | round end),
     seconds_above_baseline: (if $sorted == [] or $baseline == "" then null
       else [$r[] | select(.rate > ($baseline | tonumber)) | .dt] | add // 0 end)}'
}

step_drill() {
  local status="" s secs
  step "drill"
  set_phase drill
  secs=$(($(jq '.settings.duration_s' "$state/runner.json") + 1800))
  host_op sync
  host_op sysctl -q vm.drop_caches=3
  # awk reads to the end: exiting at the match can end ip with SIGPIPE, and
  # under pipefail that stops the run.
  nic_if="$(q host_read ip route get 1.1.1.1 | awk 'dev == "" { for (i = 1; i < NF; i++) if ($i == "dev") { dev = $(i + 1); break } }
    END { if (dev != "") print dev }')"
  : >"$RUN/ethtool-pre.txt"
  : >"$RUN/ethtool-post.txt"
  : >"$RUN/nic.csv"
  [ -z "$nic_if" ] || q host_read ethtool -S "$nic_if" >"$RUN/ethtool-pre.txt"
  io_dev="$(instance_store_dev 2>/dev/null || true)"
  io_dev="${io_dev##*/}"
  : >"$RUN/io.csv"
  # One row before the drill starts, as the baseline for the counters.
  io_line
  sample &
  sampler=$!
  rj --arg t "$(now)" '.time.drill_started_at = $t'
  "${SMELT_ENV[@]}" PROFILE=import LABEL="$run_id" STOP_INGEST_AT="$size" DURATION="$duration" WORKERS="$WORKERS" \
    RAMP="${RAMP:-}" WINDOW="${WINDOW:-}" VERIFY_LAG_MIN="${VERIFY_LAG_MIN:-}" VERIFY_LAG_MAX="${VERIFY_LAG_MAX:-}" \
    RATE_TARGET="${RATE_TARGET:-}" ACCOUNTS="${ACCOUNTS:-}" RESTORE_SCALE="${RESTORE_SCALE:-}" \
    ENFORCE_FLOOR="${ENFORCE_FLOOR:-}" PROGRESS="${PROGRESS:-}" KEEP_OBJECTS="${KEEP_OBJECTS:-}" \
    DISK_FACTOR="${DISK_FACTOR:-}" CONFIG_NOTE="forge-perf/$run_id" \
    PERF_EXTRA_METADATA="$(jq -nc --arg id "$run_id" --arg s "$series" '{forge_perf: {run_id: $id, series: $s}}')" \
    timeout --signal=INT --kill-after=300 "$secs" "$SMELT/scripts/perf-drill.sh" run &
  drill_pid=$!
  # A stop request interrupts `wait`; wait again until the drill has exited.
  # timeout passes the SIGINT on and kills the drill 5 minutes later.
  while [ -z "$status" ]; do
    s=0
    wait "$drill_pid" || s=$?
    if [ "$s" -le 128 ] || ! kill -0 "$drill_pid" 2>/dev/null; then status=$s; fi
  done
  drill_pid=""
  kill "$sampler" 2>/dev/null || true
  sampler=""
  echo "$status" >"$RUN/perf-drill.exit"
  rj --arg t "$(now)" '.time.drill_finished_at = $t'
  [ -z "$nic_if" ] || q host_read ethtool -S "$nic_if" >"$RUN/ethtool-post.txt"
  rj --argjson nic "$(nic_facts)" '.nic = $nic'
  [ ! -e "$RUN/disk-low" ] || add_reason disk_low
  if [ -n "$stop_requested" ]; then
    add_reason drill_interrupted
    exit "$stop_requested"
  fi
  case "$status" in
    124 | 137) rj '.watchdog_fired = true' ;;
  esac
}

step_check() {
  local status=0 modified
  step "check"
  # Exit 1 and 2 leave their check lines in latency.json for the record.
  timeout --kill-after=60 300 "$here/netem.sh" verify post || status=$?
  case "$status" in
    0 | 1 | 2) ;;
    124 | 137) add_reason step_timeout ;;
    *) add_reason runner_error ;;
  esac
  modified="$(git -C "$FORGE_PERF_CHECKOUT" status --porcelain)"
  if [ -n "$modified" ] && ! { host_ops_skipped && [ "${FORGE_PERF_ALLOW_MODIFIED:-}" = 1 ]; }; then
    add_reason instrument_modified
  fi
}

# close_out: collect, record, send to Grafana, upload and wipe, whether a step stopped the run
# or not. It runs from the EXIT trap without set -e, so each step checks its
# own result. Fails when no record was written or the wipe failed.
close_out() {
  local raw="$FORGE_PERF_OUTBOX/$run_id.raw.tar.zst" record="$FORGE_PERF_OUTBOX/$run_id.json" status=0 ok=0
  local forbid="$SECRETS/forbid" smelt_run id="${SMELT_PIRI_S3_ACCESS_KEY_ID:-}" secret="${SMELT_PIRI_S3_SECRET_ACCESS_KEY:-}"
  trap 'echo "run.sh: stop requested; finishing the record and the wipe" >&2' TERM INT
  [ -z "$sampler" ] || kill "$sampler" 2>/dev/null
  if [ -n "$drill_pid" ]; then
    kill -INT "$drill_pid" 2>/dev/null
    wait "$drill_pid"
  fi

  collector_close
  step "collect"
  mkdir -p "$FORGE_PERF_OUTBOX" "$SECRETS"
  [ ! -d "$RUN" ] || q host_read journalctl -u forge-perf-run --since "@$started_epoch" --no-pager >"$RUN/journal.txt"
  # piri's pair and the harness credential, which no collected file may hold.
  (
    umask 077
    : >"$forbid"
    if [ "${#id}" -ge 8 ] && [ "${#secret}" -ge 8 ]; then
      { printf '%s\n' "$id" "$secret"; cat "$SECRETS/harness-key" "$SECRETS/harness-token" 2>/dev/null; } |
        awk '{ gsub(/^[ \t]+|[ \t\r]+$/, "") } length($0) >= 8' >"$forbid"
    fi
  )
  timeout --kill-after=60 600 "$here/collect.sh" "$raw" "$forbid" "run=$RUN" "perf-runs=$SMELT/generated/perf-runs" ||
    status=$?
  if [ "$status" -ne 0 ]; then
    echo "run.sh: no raw tarball (collect.sh exited $status); the record carries raw_missing" >&2
    rj '.raw_missing = true'
  fi

  step "record"
  get_denylist || echo "run.sh: no denylist at $DENYLIST, or SSM did not answer" >&2
  rj --arg t "$(now)" '.time.run_finished_at = $t'
  smelt_run="$(find "$SMELT/generated/perf-runs/drill" -mindepth 1 -maxdepth 1 -type d -name "*-$run_id" 2>/dev/null)"
  set -- build --runner "$state/runner.json" --latency "$RUN/netem/latency.json" --traces "$RUN/traces" \
    --denylist "$DENYLIST" --out "$record"
  [ -z "$smelt_run" ] || [ "$(wc -l <<<"$smelt_run")" -ne 1 ] || set -- "$@" --run-dir "$smelt_run"
  [ ! -s "$forbid" ] || set -- "$@" --forbid "$forbid"
  status=0
  python3 "$here/record.py" "$@" || status=$?
  if [ "$status" -eq 0 ] || [ "$status" -eq 3 ]; then
    record_class="$(jq -r '.outcome | "\(.class) (\(.reasons | join(" ")))"' "$record")"
    # The outbox upload removes the record; experiment.sh reads this copy.
    if [ "$kind" = experiment ]; then
      mkdir -p "$state/experiment/records"
      cp "$record" "$state/experiment/records/$run_id.json" || echo "run.sh: cannot keep the record for the experiment" >&2
    fi
    set_phase recorded
  else
    echo "run.sh: record.py wrote no record (exit $status)" >&2
    ok=1
  fi

  # A stop request leaves Grafana out and the upload to the next poll, so the
  # wipe fits in the unit's TimeoutStopSec.
  if [ -z "$stop_requested" ]; then
    grafana_export "$state/runner.json" "$record" "$RUN"
    step "upload"
    "$here/outbox.sh" flush || echo "run.sh: the outbox keeps files for the next poll" >&2
    [ "$ok" -ne 0 ] || set_phase uploaded
  fi

  step "wipe"
  [ "$ok" -ne 0 ] || set_phase wiping
  if timeout --kill-after=60 1800 "$here/wipe.sh"; then
    rm -f "$state/current.json"
  else
    echo "run.sh: the wipe failed; current.json stays for the next boot's recovery" >&2
    ok=1
  fi
  return "$ok"
}

# A stop request (systemctl stop, TimeoutStartSec) during the drill interrupts
# it so it can still write its evidence; at any other point the run ends at
# once. Either way the run is then recorded and wiped.
on_stop() {
  stop_requested="$1"
  if [ -n "$drill_pid" ]; then
    echo "run.sh: stop requested; interrupting the drill" >&2
    kill -INT "$drill_pid" 2>/dev/null || true
  else
    add_reason drill_interrupted
    exit "$1"
  fi
}

# --- the run ----------------------------------------------------------------------

last="$(jq -c . "$state/last-started.json" 2>/dev/null || echo null)"
tracked_refs="$(sed 's/#.*//' "$cfg/images.tracked" | awk 'NF == 2 { print $2 }' | jq -Rsc 'split("\n") - [""]')"
changed="$(jq -c --argjson last "$last" --argjson tracked "$tracked_refs" '. as $cur |
  [($tracked[] | select($last == null or $last.images[.] != $cur.images[.]) | sub(":.*$"; "") | sub("^.*/"; "")),
   (if $last == null or $last.smelt != .smelt then "smelt" else empty end),
   (if $last == null or $last.harness.sha != .harness.sha then "harness" else empty end)] | sort' <<<"$set_json")"
case "$kind" in
  manual | nightly) reason="$kind" ;;
  campaign) reason="$([ "$pairing" = null ] && echo campaign || echo pairing)" ;;
  # An experiment's branch run differs from its main run in one image.
  experiment)
    reason=experiment
    changed="$(jq -c 'if .role == "branch" then [.service] else [] end' <<<"$experiment")" ;;
  *) reason="$(jq -r 'if any(.[]; . != "smelt" and . != "harness") or . == [] then "image"
    elif any(.[]; . == "smelt") then "smelt" else "harness" end' <<<"$changed")" ;;
esac

images_json="$(printf '%s\n' "${pinned[@]}" | jq -Rsc 'split("\n") - [""] | map(split(" ") |
  {variable: .[0], repo: .[1], ref: .[2], digest: .[3], role: .[4], revision: null, source: null,
   services: []})')"
jq -n --arg run_id "$run_id" --arg series "$series" --argjson pairing "$pairing" --arg reason "$reason" \
  --argjson changed "$changed" --argjson superseded "$superseded" --argjson box "$(box_facts)" \
  --arg started "$started" --argjson settings "$settings_json" \
  --arg fp "$(git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)" --arg tree "$(instrument_tree)" \
  --arg smelt "$smelt_sha" --arg harness "$harness_sha" --argjson images "$images_json" --argjson caps "$caps" \
  --arg trace "$trace" --arg budget "$budget" --argjson experiment "$experiment" '
  {run_id: $run_id, series: $series, pairing_id: $pairing, experiment: $experiment,
   trigger: {reason: $reason, changed: $changed},
   superseded: $superseded, box: $box,
   time: {run_started_at: $started, stack_up_at: null, drill_started_at: null, drill_finished_at: null,
          run_finished_at: null},
   settings: $settings,
   provenance: {forge_perf: {sha: $fp, instrument_tree: $tree}, smelt: {sha: $smelt}, harness: {sha: $harness}},
   images: $images, reasons: [], restarted_services: [], watchdog_fired: false,
   nic: {allowance_exceeded: null, egress_bytes_per_s_median: null, seconds_above_baseline: null},
   raw_missing: false, caps: $caps, trace: (if $trace == "" then null else {ratio: $trace} end),
   ingot_local_blob_max_bytes: (if $budget == "" then null else ($budget | tonumber) end)}' \
  >"$state/runner.json.tmp"
mv "$state/runner.json.tmp" "$state/runner.json"
stop_requested="" drill_pid="" sampler="" nic_if="" io_dev="" record_class=""
trap finish EXIT
trap 'on_stop 143' TERM
trap 'on_stop 130' INT
set_phase preflight
# An experiment's run leaves last-started.json as the live series had it, so
# the next pass neither re-pends main's set nor skips a set that is pending.
case "$from_pending" in
  experiment) rm -f "$pending_file" "$state/experiment/last-run.json" ;;
  *)
    jq . <<<"$set_json" | write_durable "$state/last-started.json"
    # A manual run leaves the poller's pending run and retry state alone.
    [ -z "$from_pending" ] || rm -f "$state/pending.json" "$state/last-run.json"
    ;;
esac
exec 8>&-
echo "run $run_id: series $series, trigger $reason, smelt $smelt_sha, harness $harness_sha"

for s in $STEPS; do
  "step_$s"
  [ "$s" != "$until" ] || break
done
