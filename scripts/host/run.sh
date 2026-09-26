#!/usr/bin/env bash
# One run of the stack against one set: smelt and harness SHAs and a digest
# for every tracked image (docs/runner.md, "A run").
#
#   run.sh [--set FILE] [--series SERIES] [--workers N] [--size SIZE]
#          [--duration DURATION] [--until STEP]
#
# Without --set it takes the run the poller left in
# $FORGE_PERF_STATE_DIR/pending.json. With --set it runs that set as a manual
# run in SERIES (per-trigger, nightly, campaign or calibration; default
# calibration). While config/launch.conf has SERIES_LIVE=0 every run is
# series calibration. --workers, --size and --duration override the settings
# file. The steps are preflight, checkout, images, boot and setup; --until
# STEP stops after STEP and leaves the stack as it is.
#
# Exit status: 0 the run reached its last step, or another run holds the lock;
# 1 a step failed, and runner.json names the reason; 2 the run did not start
# (usage, no settings for this instance type, WORKERS empty, an unusable set).
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

STEPS="preflight checkout images boot setup"
refuse() {
  echo "run.sh: $*" >&2
  exit 2
}
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }

set_file="" series="" workers="" size="" duration="" until=setup
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --set) set_file="$2" ;;
    --series) series="$2" ;;
    --workers) workers="$2" ;;
    --size) size="$2" ;;
    --duration) duration="$2" ;;
    --until) until="$2" ;;
    *) usage ;;
  esac
  shift 2
done
grep -qw -- "$until" <<<"$STEPS" || refuse "--until takes one of: $STEPS"

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
# shellcheck source=../../config/latency.env
. "$cfg/latency.env"
instance_type="$(imds instance-type)"
settings="$cfg/settings/$instance_type.env"
[ -r "$settings" ] || refuse "no settings file for instance type $instance_type ($settings)"
# shellcheck disable=SC1090
. "$settings"

# --- the set, the series and the drill settings -------------------------------

kind=manual superseded=0 pairing=null
if [ -n "$set_file" ]; then
  set_json="$(jq -ce 'objects' "$set_file")" || refuse "$set_file is not a JSON object"
else
  [ -e "$state/pending.json" ] || { echo "run.sh: nothing pending"; exit 0; }
  # An unreadable pending run is moved aside, so the next poll does not start it again.
  pending="$(jq -ce 'objects | select(.set | type == "object")' "$state/pending.json")" || {
    mv "$state/pending.json" "$state/pending.json.rejected"
    refuse "pending.json is not a JSON object with a set; moved to pending.json.rejected"
  }
  set_json="$(jq -c '.set' <<<"$pending")"
  kind="$(jq -r '.kind // "trigger"' <<<"$pending")"
  superseded="$(jq '.superseded // 0' <<<"$pending")"
  pairing="$(jq -c '.pairing_id // null' <<<"$pending")"
  # A campaign's own workers, size and duration, unless the command line says.
  for v in workers size duration; do
    [ -n "${!v}" ] || printf -v "$v" '%s' "$(jq -r --arg v "$v" '.[$v] // empty' <<<"$pending")"
  done
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
  campaign) series=campaign ;;
  *) refuse "pending.json has kind '$kind'" ;;
esac
grep -qxE 'per-trigger|nightly|campaign|calibration' <<<"$series" || refuse "unknown series '$series'"
[ "${SERIES_LIVE:-0}" = 1 ] || series=calibration

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

# The pinned images: VARIABLE repo tag digest role, and each exported as
# VARIABLE=repo@digest for every compose call of the run.
pinned=()
while read -r var ref digest; do
  role=instrument
  if [ -z "$digest" ]; then
    role=under_test
    digest="$(jq -r --arg ref "$ref" '.images[$ref] // ""' <<<"$set_json")"
  fi
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || refuse "no digest for $ref in the set or config/images.lock"
  pinned+=("$var ${ref%:*} ${ref##*:} $digest $role")
  export "$var=${ref%:*}@$digest"
done < <(sed 's/#.*//' "$cfg/images.tracked" | awk 'NF == 2' && sed 's/#.*//' "$cfg/images.lock" | awk 'NF == 3')

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_id="$FORGE_PERF_BOX_ID-$(tr -d ':-' <<<"$started" | tr TZ tz)"
WORK="$FORGE_PERF_WORK" SMELT="$FORGE_PERF_WORK/smelt" SQ="$FORGE_PERF_WORK/storage-qualification"
RUN="$FORGE_PERF_WORK/run" MIRRORS="${FORGE_PERF_MIRRORS:-/var/lib/forge-perf/mirror}"
SSM="${FORGE_PERF_SSM_PATH:-/forge-perf}" SECRETS="$FORGE_PERF_RUNTIME/secrets"
[ -n "${FORGE_PERF_PIRI_BUCKET_PREFIX:-}" ] || refuse "FORGE_PERF_PIRI_BUCKET_PREFIX is not set"
smelt_prefix="${FORGE_PERF_SMELT_BUCKET_PREFIX:-${FORGE_PERF_PIRI_BUCKET_PREFIX%piri-0-}}"

# The host's own AWS calls go to the box's region. smelt's s3-key.sh writes
# the drill's key with `aws configure set`, which lands on tmpfs.
export AWS_REGION="${FORGE_PERF_REGION:-us-east-2}" AWS_CONFIG_FILE="$FORGE_PERF_RUNTIME/aws/config"
export AWS_SHARED_CREDENTIALS_FILE="$FORGE_PERF_RUNTIME/aws/credentials" GIT_TERMINAL_PROMPT=0
export SMELT_WORKSPACE=0 STORAGE_QUALIFICATION_DIR="$SQ" GOWORK=off
export PIRI_INDEXER=off SPRUE_INDEXER_ENDPOINT='' SPRUE_INDEXER_DID=''
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
    --arg model "$model" --arg bytes "$bytes" --arg fs "$(q host_read findmnt -no FSTYPE "$FORGE_PERF_NVME_MOUNT")" '
    def n: if . == "" then null else . end;
    def num: if . == "" then null else tonumber end;
    {id: $id, tier: ($tier | num), instance_type: $type, arch: $arch, region: $region,
     availability_zone: ($az | n), ami_id: ($ami | n), kernel: $kernel, docker_server: ($docker | n),
     docker_compose: ($compose | n),
     cpu: {implementer: ($impl | n), part: ($part | n), cores: ($cores | num),
           features: ($features | split(" ") | map(select(. != "")))},
     mem_total_bytes: ($mem | num), nvme: {model: ($model | n), size_bytes: ($bytes | num), filesystem: ($fs | n)}}'
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
  jq -n --arg id "$run_id" --arg phase "$1" --arg dir "$RUN" '{run_id: $id, phase: $phase, run_dir: $dir}' \
    >"$state/current.json.tmp"
  mv "$state/current.json.tmp" "$state/current.json"
}

# stop REASON MESSAGE: the run cannot go on.
failed=""
stop() {
  echo "run.sh: $1: $2" >&2
  failed="$1"
  rj --arg r "$1" '.reasons = (.reasons + [$r] | unique)'
  exit 1
}

finish() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && [ -z "$failed" ]; then
    rj '.reasons = (.reasons + ["runner_error"] | unique)'
  fi
  rm -f "$state/current.json"
  if [ "$status" -eq 0 ]; then
    echo "run $run_id: $until done; the stack stays up until scripts/host/wipe.sh"
  else
    echo "run $run_id stopped: $(jq -r '.reasons | join(" ")' "$state/runner.json")" >&2
  fi
  exit "$status"
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

ssm_value() {
  aws ssm get-parameter --with-decryption --name "$1" --query Parameter.Value --output text
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
}

step_preflight() {
  local modified docker_major
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
  [[ "$FORGE_PERF_PIRI_BUCKET_PREFIX" = "${smelt_prefix}piri-0-" ]] ||
    stop runner_error "FORGE_PERF_PIRI_BUCKET_PREFIX must be the smelt bucket prefix followed by piri-0-"

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
}

# harness_git: how git reaches the harness repository, in HARNESS_GIT (a
# command prefix) and HARNESS_URL. FORGE_PERF_HARNESS_AUTH: deploy-key (an
# SSH key in SSM), app (a GitHub App installation token minted from the
# App's key in SSM) or none (the caller's own git credentials).
harness_git() {
  local auth="${FORGE_PERF_HARNESS_AUTH:-deploy-key}"
  case "$auth" in
    deploy-key)
      HARNESS_URL="${FORGE_PERF_HARNESS_URL:-git@github.com:$SQ_REPO.git}"
      (umask 077 && ssm_value "${FORGE_PERF_HARNESS_CREDENTIAL_PARAM:-$SSM/harness-deploy-key}" \
        >"$SECRETS/harness-key") || stop secrets_unavailable "cannot read the harness deploy key from SSM"
      HARNESS_GIT=(env "GIT_SSH_COMMAND=ssh -i $SECRETS/harness-key -o IdentitiesOnly=yes \
-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$cfg/github-known-hosts" git)
      ;;
    app)
      HARNESS_URL="${FORGE_PERF_HARNESS_URL:-https://x-access-token@github.com/$SQ_REPO.git}"
      "$here/harness-token.sh" "${FORGE_PERF_HARNESS_APP_PARAM:-$SSM/harness-app}" "$SECRETS" ||
        stop secrets_unavailable "cannot mint a harness token from the GitHub App key in SSM"
      local helper="!f() { [ \"\$1\" = get ] && printf 'username=x-access-token\npassword=%s\n' \"\$(cat '$SECRETS/harness-token')\"; }; f"
      HARNESS_GIT=(git -c credential.helper= -c "credential.helper=$helper")
      ;;
    none)
      HARNESS_URL="${FORGE_PERF_HARNESS_URL:-https://github.com/$SQ_REPO.git}"
      HARNESS_GIT=(git)
      ;;
    *) stop runner_error "FORGE_PERF_HARNESS_AUTH must be deploy-key, app or none" ;;
  esac
}

# mirror NAME URL SHA REASON GIT...: fetch every branch and pull request head
# into the bare mirror, so a commit stays reachable after its branch is
# deleted on merge, then require SHA. A failed fetch only stops the run when
# the commit is not already there.
mirror() {
  local name="$1" url="$2" sha="$3" reason="$4" dir="$MIRRORS/$1.git"
  shift 4
  [ -d "$dir" ] || git init -q --bare "$dir"
  git -C "$dir" config remote.origin.url "$url"
  git -C "$dir" config --replace-all remote.origin.fetch '+refs/heads/*:refs/heads/*'
  git -C "$dir" config --add remote.origin.fetch '+refs/pull/*/head:refs/pull/*/head'
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
  harness_git
  mirror smelt "${FORGE_PERF_SMELT_URL:-https://github.com/$SMELT_REPO.git}" "$smelt_sha" smelt_unreachable git
  mirror storage-qualification "$HARNESS_URL" "$harness_sha" harness_unreachable "${HARNESS_GIT[@]}"
  git clone -q --no-checkout "$MIRRORS/smelt.git" "$SMELT" &&
    git -C "$SMELT" checkout -q --detach "$smelt_sha" || stop runner_error "cannot check out smelt $smelt_sha"
  git clone -q --no-checkout "$MIRRORS/storage-qualification.git" "$SQ" &&
    git -C "$SQ" checkout -q --detach "$harness_sha" || stop runner_error "cannot check out the harness $harness_sha"
  # The smelt settings a run depends on; an older smelt would run another stack.
  for knob in KEEP_OBJECTS DISK_FACTOR PERF_EXTRA_METADATA; do
    grep -q "$knob" "$SMELT/scripts/perf-drill.sh" || stop runner_error "smelt $smelt_sha has no $knob in perf-drill.sh"
  done
  grep -q PIRI_INDEXER "$SMELT/systems/piri/entrypoint.sh" || stop runner_error "smelt $smelt_sha has no PIRI_INDEXER"
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
  listed="$(cd "$SMELT" && "${SMELT_ENV[@]}" docker compose config --images)" ||
    stop runner_error "docker compose config failed"
  bad="$(grep -vxF -f <(printf '%s\n' "$refs") <<<"$listed" || true)"
  [ -z "$bad" ] || stop runner_error "images outside the pinned set: $(tr '\n' ' ' <<<"$bad")"

  printf '%s\n' "${pinned[@]}" | awk '{ print $1, $2 ":" $3, $4 }' >"$state/images.pinned"
  : >"$RUN/pull.list"
  while read -r line; do
    docker image inspect "$line" >/dev/null 2>&1 || echo "$line" >>"$RUN/pull.list"
  done <<<"$refs"
  if [ -s "$RUN/pull.list" ]; then
    within 1200 image_pull_failed xargs -P4 -n1 docker pull --quiet <"$RUN/pull.list"
  fi

  (cd "$SMELT" && "${SMELT_ENV[@]}" docker compose config --format json) >"$RUN/compose.json" ||
    stop runner_error "docker compose config failed"
  rj --slurpfile c "$RUN/compose.json" '.images |= map(. as $i | .services =
    if $i.variable == "NETSHOOT_IMAGE" then ["netem"]
    else [$c[0].services | to_entries[] | select(.value.image == $i.repo + "@" + $i.digest) | .key] | sort end)'
}

step_boot() {
  step "boot"
  set_phase boot
  docker network create --driver bridge --subnet "$NET_SUBNET" forge-network >/dev/null ||
    stop stack_boot_failed "cannot create forge-network on $NET_SUBNET"
  within 900 stack_boot_failed "${SMELT_ENV[@]}" make -C "$SMELT" up
  rj --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.time.stack_up_at = $t'
}

step_setup() {
  local ingot ip
  step "setup"
  case "${FORGE_PERF_CLIENT_PATH:-container-ip}" in
    container-ip)
      # Straight to ingot's bridge address, past Docker's userland proxy.
      ingot="$(cd "$SMELT" && docker compose ps -q ingot)" || stop setup_failed "no ingot container"
      ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "forge-network"}}{{.IPAddress}}{{end}}' "$ingot")" ||
        stop setup_failed "cannot read ingot's forge-network address"
      [ -n "$ip" ] || stop setup_failed "ingot has no forge-network address"
      export INGOT_URL="http://$ip:80"
      ;;
    published) unset INGOT_URL ;;
    *) stop runner_error "FORGE_PERF_CLIENT_PATH must be container-ip or published" ;;
  esac
  within 600 setup_failed "${SMELT_ENV[@]}" "$SMELT/scripts/perf-drill.sh" setup
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
  *) reason="$(jq -r 'if any(.[]; . != "smelt" and . != "harness") or . == [] then "image"
    elif any(.[]; . == "smelt") then "smelt" else "harness" end' <<<"$changed")" ;;
esac

images_json="$(printf '%s\n' "${pinned[@]}" | jq -Rsc 'split("\n") - [""] | map(split(" ") |
  {variable: .[0], repo: .[1], ref: .[2], digest: .[3], role: .[4], services: []})')"
jq -n --arg run_id "$run_id" --arg series "$series" --argjson pairing "$pairing" --arg reason "$reason" \
  --argjson changed "$changed" --argjson superseded "$superseded" --argjson box "$(box_facts)" \
  --arg started "$started" --argjson settings "$settings_json" \
  --arg fp "$(git -C "$FORGE_PERF_CHECKOUT" rev-parse HEAD)" --arg tree "$(instrument_tree)" \
  --arg smelt "$smelt_sha" --arg harness "$harness_sha" --argjson images "$images_json" '
  {run_id: $run_id, series: $series, pairing_id: $pairing, trigger: {reason: $reason, changed: $changed},
   superseded: $superseded, box: $box,
   time: {run_started_at: $started, stack_up_at: null, drill_started_at: null, drill_finished_at: null,
          run_finished_at: null},
   settings: $settings,
   provenance: {forge_perf: {sha: $fp, instrument_tree: $tree}, smelt: {sha: $smelt}, harness: {sha: $harness}},
   images: $images, reasons: [], restarted_services: [], watchdog_fired: false,
   nic: {allowance_exceeded: null, egress_bytes_per_s_median: null, seconds_above_baseline: null},
   raw_missing: false}' >"$state/runner.json.tmp"
mv "$state/runner.json.tmp" "$state/runner.json"
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
set_phase preflight
jq . <<<"$set_json" >"$state/last-started.json"
rm -f "$state/pending.json"
echo "run $run_id: series $series, trigger $reason, smelt $smelt_sha, harness $harness_sha"

for s in $STEPS; do
  "step_$s"
  [ "$s" != "$until" ] || break
done
