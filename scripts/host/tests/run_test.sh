#!/usr/bin/env bash
# Behavior of run.sh from preflight to setup, against stubbed docker, aws,
# make, go and instance metadata, with real git. Each case runs in a scratch
# commit of this repository (so `git status` is clean and a hand edit can be
# tested) against local smelt and harness repositories whose history the
# mirrors fetch. The harness commit is reachable only through a pull request
# head, as the pinned one is once its branch is deleted.
# shellcheck disable=SC2016,SC2015 # stubs expand their own variables; fail exits
set -euo pipefail

host="$(cd "$(dirname "$0")/.." && pwd -P)"
repo="$(cd "$host/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/run-test.XXXXXX")"
# KEEP_WORK=1 keeps the scratch directory for inspection.
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$work"' EXIT
export D="$work/d"
mkdir -p "$work/bin" "$D"
unset INVOCATION_ID FORGE_PERF_HOST_OPS FORGE_PERF_LOCK_HELD AWS_ENDPOINT_URL AWS_PROFILE
export PYTHONDONTWRITEBYTECODE=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$D/docker.log"
case "$*" in
  "version --format"*) echo 28.5.1 ;;
  "compose version --short") echo 2.40.3 ;;
  "ps -aq"*) [ -z "${DOCKER_HANG:-}" ] || exec sleep 10; cat "$D/containers" 2>/dev/null ;;
  "volume ls -q"*) cat "$D/volumes" 2>/dev/null ;;
  "network inspect forge-network") [ -e "$D/network" ] ;;
  "network create"*) touch "$D/network" ;;
  "image inspect"*) grep -qxF "${!#}" "$D/images" ;;
  "pull --quiet"*) echo "${!#}" >>"$D/images" ;;
  "compose config --images")
    for v in INGOT_IMAGE PIRI_IMAGE UPLOAD_IMAGE POSTGRES_IMAGE IPNI_IMAGE ${EXTRA_IMAGE_VAR:-}; do echo "${!v}"; done ;;
  "compose config --format json")
    # As smelt's generator does: piri-0 gets the manifest's S3 target and the
    # key from SMELT_PIRI_S3_*. OLD_SMELT: a smelt without storage.s3.
    ep="$(sed -n 's/^ *endpoint: //p' "$SMELT_MANIFEST")" pre="$(sed -n 's/^ *bucket_prefix: //p' "$SMELT_MANIFEST")piri-0-"
    [ -z "${OLD_SMELT:-}" ] || ep=piri-minio:9000 pre=piri-0-
    jq -n --arg ep "$ep" --arg pre "$pre" --arg old "${OLD_SMELT:-}" '{services: ({ingot: {image: env.INGOT_IMAGE},
      "piri-0": {image: env.PIRI_IMAGE, environment: {PIRI_S3_ENDPOINT: $ep, PIRI_S3_BUCKET_PREFIX: $pre,
        PIRI_S3_ACCESS_KEY_ID: (env.SMELT_PIRI_S3_ACCESS_KEY_ID // ""),
        PIRI_S3_SECRET_ACCESS_KEY: (env.SMELT_PIRI_S3_SECRET_ACCESS_KEY // "")}},
      upload: {image: env.UPLOAD_IMAGE}, "upload-init": {image: env.UPLOAD_IMAGE},
      postgres: {image: env.POSTGRES_IMAGE}, ipni: {image: env.IPNI_IMAGE}}
      + if $old == "" then {} else {"piri-minio": {image: env.POSTGRES_IMAGE}} end)}' ;;
  "compose ps -q ingot") echo cid-ingot ;;
  "inspect -f"*) echo 172.30.0.5 ;;
  *) echo "docker stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$D/aws.log"
case " $* " in
  *" list-objects-v2 "*) [ ! -e "$D/s3-down" ] || exit 255; if [ -e "$D/objects" ]; then echo 1; else echo 0; fi ;;
  *" ssm get-parameter "*)
    [ ! -e "$D/ssm-down" ] || exit 255
    case "$*" in
      *piri-s3-access-key-id*) echo AKIAFAKEKEYID ;;
      *piri-s3-secret-access-key*) echo fake-secret-value ;;
      *) exit 254 ;;
    esac ;;
  *) echo "aws stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
# IMDSv2: a token, then meta-data. IMDS_DOWN makes it unreachable (a laptop).
cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -z "${IMDS_DOWN:-}" ] || exit 7
for a; do
  case "$a" in
    */latest/api/token) echo token; exit 0 ;;
    */meta-data/instance-type) echo m9gd.2xlarge; exit 0 ;;
    */meta-data/placement/availability-zone) echo us-east-2a; exit 0 ;;
    */meta-data/ami-id) echo ami-0123456789abcdef0; exit 0 ;;
  esac
done
exit 22
STUB
cat >"$work/bin/make" <<'STUB'
#!/usr/bin/env bash
echo "make $*" >>"$D/make.log"
if [ "${!#}" = up ]; then
  env | grep -E '^(PIRI_INDEXER|SPRUE_INDEXER_[A-Z]+|SMELT_PIRI_S3_[A-Z_]+|INGOT_IMAGE|POSTGRES_IMAGE|AWS_[A-Z_]+|SMELT_WORKSPACE)=' |
    sort >"$D/up.env"
  exit "${UP_EXIT:-0}"
fi
STUB
printf '#!/usr/bin/env bash\necho "go $*" >>"$D/go.log"\n' >"$work/bin/go"
printf '#!/usr/bin/env bash\necho "${NTP:-yes}"\n' >"$work/bin/timedatectl"
printf '#!/usr/bin/env bash\n[ "$1" = -u ] && echo 0 || /usr/bin/id "$@"\n' >"$work/bin/id"
for tool in flock modprobe; do printf '#!/usr/bin/env bash\n' >"$work/bin/$tool"; done
# One instance-store NVMe beside the root EBS volume. NO_NVME: none is found.
cat >"$work/bin/lsblk" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-dno PATH,MODEL")
    echo "/dev/nvme0n1 Amazon Elastic Block Store"
    [ -n "${NO_NVME:-}" ] || echo "/dev/nvme1n1 Amazon EC2 NVMe Instance Storage" ;;
  "-dno MODEL /dev/nvme1n1") echo "Amazon EC2 NVMe Instance Storage    " ;;
  "-bdno SIZE /dev/nvme1n1") echo " 474000000000" ;;
  *) exit 1 ;;
esac
STUB
printf '#!/usr/bin/env bash\necho ext4\n' >"$work/bin/findmnt"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

# The smelt and harness repositories the mirrors fetch.
git init -q "$work/smelt-src"
mkdir -p "$work/smelt-src/scripts" "$work/smelt-src/systems/piri"
cat >"$work/smelt-src/scripts/perf-drill.sh" <<'STUB'
#!/usr/bin/env bash
# KEEP_OBJECTS DISK_FACTOR PERF_EXTRA_METADATA
echo "$1 INGOT_URL=${INGOT_URL:-unset} AWS_REGION=${AWS_REGION:-unset}" >>"$D/drill.log"
exit "${SETUP_EXIT:-0}"
STUB
chmod +x "$work/smelt-src/scripts/perf-drill.sh"
echo 'PIRI_INDEXER=${PIRI_INDEXER:-on}' >"$work/smelt-src/systems/piri/entrypoint.sh"
git -C "$work/smelt-src" add -A && git -C "$work/smelt-src" commit -qm smelt
smelt_sha="$(git -C "$work/smelt-src" rev-parse HEAD)"
git init -q "$work/sq-src"
git -C "$work/sq-src" commit -q --allow-empty -m main
git -C "$work/sq-src" checkout -q -b feature
git -C "$work/sq-src" commit -q --allow-empty -m pinned
sq_sha="$(git -C "$work/sq-src" rev-parse HEAD)"
git -C "$work/sq-src" update-ref refs/pull/5/head "$sq_sha"
git -C "$work/sq-src" checkout -q -
git -C "$work/sq-src" branch -q -D feature

mkdir -p "$work/root/proc"
printf 'processor\t: 0\nFeatures\t: fp asimd aes pmull sha1 sha2 crc32\nCPU implementer\t: 0x41\nCPU part\t: 0xd4f\n' \
  >"$work/root/proc/cpuinfo"
printf 'MemTotal:       32450648 kB\n' >"$work/root/proc/meminfo"

images_json="$(sed 's/#.*//' "$repo/config/images.tracked" | awk 'NF == 2 { print $2 }' |
  jq -Rn '[inputs | {(.): ("sha256:" + ("0" * 63) + (input_line_number | tostring | .[-1:]))}] | add')"

fail() {
  echo "FAIL: $*" >&2
  for f in "$D"/*.log "$work/out"; do [ ! -e "$f" ] || { echo "--- $f" >&2; tail -20 "$f" >&2; }; done
  exit 1
}

# setup [checkout edits...]: a fresh box and a scratch commit of the repo.
setup() {
  rm -rf "$D" "$work/box" "$work/checkout"
  mkdir -p "$D" "$work/box/state" "$work/box/nvme" "$work/box/run" "$work/checkout"
  echo "${INGOT_IMAGE_REF:-postgres@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea}" \
    >"$D/images"
  (cd "$repo" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar cf - 2>/dev/null) |
    tar xf - -C "$work/checkout"
  # The wipe itself is tested in wipe_test.sh; here it clears the stubs' state.
  printf '#!/usr/bin/env bash\necho wipe >>"$D/wipe.log"\nrm -f "$D/containers" "$D/volumes" "$D/network" "$D/objects"\n' \
    >"$work/checkout/scripts/host/wipe.sh"
  git -C "$work/checkout" init -q
  git -C "$work/checkout" add -A
  git -C "$work/checkout" commit -qm checkout
  printf '%s\n' FORGE_PERF_BOX_ID=main "FORGE_PERF_CHECKOUT=$work/checkout" \
    FORGE_PERF_PIRI_BUCKET_PREFIX=forge-perf-piri-main-1-piri-0- >"$work/box/box.conf"
  jq -n --arg smelt "$smelt_sha" --arg sq "$sq_sha" --argjson images "$images_json" \
    '{smelt: $smelt, harness: {sha: $sq, pinned: true, main: null}, images: $images}' >"$work/set.json"
}

# run EXPECTED-STATUS [VAR=value...] -- [run.sh args...]
run() {
  local want="$1" got=0 envs=()
  shift
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env ${envs[@]+"${envs[@]}"} FORGE_PERF_BOX_CONF="$work/box/box.conf" FORGE_PERF_STATE_DIR="$work/box/state" \
    FORGE_PERF_NVME_MOUNT="$work/box/nvme" FORGE_PERF_RUNTIME="$work/box/run" FORGE_PERF_OUTBOX="$work/box/outbox" \
    FORGE_PERF_MIRRORS="$work/box/mirror" FORGE_PERF_GO_CACHE= FORGE_PERF_HOST_ROOT="$work/root" \
    FORGE_PERF_IMDS_URL=http://imds.test FORGE_PERF_SMELT_URL="$work/smelt-src" \
    FORGE_PERF_HARNESS_AUTH=none FORGE_PERF_HARNESS_URL="$work/sq-src" \
    bash "$work/checkout/scripts/host/run.sh" "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "expected exit $want, got $got"
}

runner() { jq -r "$1" "$work/box/state/runner.json"; }

# WORKERS is empty in m9gd.2xlarge.env.
setup
run 2 -- --set "$work/set.json"
grep -q "WORKERS is empty" "$work/out" || fail "no WORKERS message"
[ ! -e "$work/box/state/runner.json" ] || fail "a refused run wrote runner.json"
echo "ok: WORKERS empty and no --workers refuses to start"

setup
run 0 -- --set "$work/set.json" --workers 16
[[ "$(runner .run_id)" =~ ^main-[0-9]{8}t[0-9]{6}z$ ]] || fail "run_id $(runner .run_id)"
[ "$(runner '.series + " " + .trigger.reason')" = "calibration manual" ] || fail "series or trigger"
[ "$(runner '.settings | "\(.workers) \(.stop_ingest_at_bytes) \(.duration_s) \(.window_s) \(.restore_scale_permille)"')" = \
  "16 100000000000 3600 30 250" ] || fail "settings $(runner .settings)"
[ "$(runner '.box | "\(.instance_type) \(.availability_zone) \(.tier) \(.cpu.implementer) \(.mem_total_bytes)"')" = \
  "m9gd.2xlarge us-east-2a 1 0x41 33229463552" ] || fail "box $(runner .box)"
[ "$(runner '[.images[] | select(.repo == "ghcr.io/fil-forge/sprue") | .services[]] | join(",")')" = upload,upload-init ] ||
  fail "sprue services"
[ "$(runner '[.images[] | select(.variable == "NETSHOOT_IMAGE") | .services[]] | join(",")')" = netem ] || fail "netshoot"
[ "$(runner '.reasons | length')" = 0 ] || fail "reasons on a clean run"
[ "$(runner '.provenance.harness.sha')" = "$sq_sha" ] || fail "harness sha"
[[ "$(runner '.provenance.forge_perf.instrument_tree')" =~ ^[0-9a-f]{64}$ ]] || fail "instrument tree"
[ "$(runner .time.stack_up_at)" != null ] || fail "no stack_up_at"
cmp -s "$work/box/state/runner.json" "$work/box/nvme/work/run/runner.json" || fail "run dir runner.json differs"
[ ! -e "$work/box/state/current.json" ] || fail "current.json left"
jq -e --arg s "$sq_sha" '.harness.sha == $s' "$work/box/state/last-started.json" >/dev/null || fail "last-started"
grep -q "network create --driver bridge --subnet 172.30.0.0/24 forge-network" "$D/docker.log" || fail "network"
grep -q "^docker pull --quiet postgres@" "$D/docker.log" && fail "pulled an image that was present"
# Every pinned image but the one already present.
want=$(($(sed 's/#.*//' "$repo/config/images.tracked" "$repo/config/images.lock" | awk 'NF >= 2' | wc -l) - 1))
[ "$(grep -c "^docker pull --quiet" "$D/docker.log")" = "$want" ] || fail "expected $want pulls"
grep -qx "PIRI_INDEXER=off" "$D/up.env" && grep -qx "SPRUE_INDEXER_DID=" "$D/up.env" || fail "indexing not off"
grep -qx "SMELT_PIRI_S3_ACCESS_KEY_ID=AKIAFAKEKEYID" "$D/up.env" || fail "piri key not passed to compose"
grep -qx "INGOT_IMAGE=ghcr.io/fil-forge/ingot@$(jq -r '.images["ghcr.io/fil-forge/ingot:main"]' "$work/set.json")" \
  "$D/up.env" || fail "INGOT_IMAGE not pinned"
grep -q '^AWS_REGION=' "$D/up.env" && fail "smelt saw the host's AWS_REGION"
grep -q "AWS_CONFIG_FILE=$work/box/run/aws/config" "$D/up.env" || fail "AWS config not on the runtime dir"
grep -qx "setup INGOT_URL=http://172.30.0.5:80 AWS_REGION=unset" "$D/drill.log" || fail "setup env"
grep -q "endpoint: s3.us-east-2.amazonaws.com" "$work/box/nvme/work/run/smelt-manifest.yml" &&
  grep -q "bucket_prefix: forge-perf-piri-main-1-$" "$work/box/nvme/work/run/smelt-manifest.yml" || fail "manifest"
grep -q "build -o bin/drill ./cmd/drill" "$D/go.log" || fail "drill not built"
echo "ok: a clean run reaches setup with every image pinned; the harness pin comes through a pull ref"

# piri's key reaches compose through the environment only, never the disk.
! grep -rqF -e AKIAFAKEKEYID -e fake-secret-value "$work/box/nvme/work" "$work/box/state" || fail "piri's key on disk"
jq -e '.piri_s3.PIRI_S3_BUCKET_PREFIX == "forge-perf-piri-main-1-piri-0-" and (.services.ingot | keys == ["image"])' \
  "$work/box/nvme/work/run/compose-images.json" >/dev/null || fail "compose-images.json"
echo "ok: piri's key stays off the disk"

# The runner.json of a clean run is enough for the minimal record, once the
# record step stamps run_finished_at as it does before any build.
echo 'zz-no-such-term-zz' >"$work/deny"
jq '.time.run_finished_at = "2026-10-01T12:00:00Z"' "$work/box/state/runner.json" >"$work/runner-done.json"
python3 "$work/checkout/scripts/host/record.py" minimal --runner "$work/runner-done.json" \
  --denylist "$work/deny" --out "$work/record.json" >/dev/null 2>&1 || fail "record.py minimal on runner.json"
[ "$(jq -r '.box.nvme | "\(.model) \(.size_bytes) \(.filesystem)"' "$work/record.json")" = \
  "Amazon EC2 NVMe Instance Storage 474000000000 ext4" ] || fail "nvme $(jq -c .box.nvme "$work/record.json")"
echo "ok: a clean run's runner.json makes a minimal record that passes the schema"

setup
run 0 -- --set "$work/set.json" --workers 16 --until images
[ ! -e "$D/make.log" ] || ! grep -q " up$" "$D/make.log" || fail "--until images booted the stack"
echo "ok: --until images stops before boot"

setup
jq '.harness.sha = "1111111111111111111111111111111111111111"' "$work/set.json" >"$work/bad.json"
run 1 -- --set "$work/bad.json" --workers 16
[ "$(runner '.reasons | join(",")')" = harness_unreachable ] || fail "reasons $(runner .reasons)"
jq '.smelt = "2222222222222222222222222222222222222222"' "$work/set.json" >"$work/bad.json"
setup
run 1 -- --set "$work/bad.json" --workers 16
[ "$(runner '.reasons | join(",")')" = smelt_unreachable ] || fail "reasons $(runner .reasons)"
echo "ok: an unreachable SHA stops with its reason"

setup
echo "# edited" >>"$work/checkout/config/latency.env"
run 1 -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = instrument_modified ] || fail "reasons $(runner .reasons)"
[ ! -d "$work/box/mirror" ] || fail "fetched after a failed preflight"
echo "ok: a hand edit in the checkout stops preflight"

setup
run 1 NTP=no -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = preflight_failed ] || fail "reasons $(runner .reasons)"
echo "ok: an unsynchronized clock stops preflight"

setup
touch "$D/network" "$D/objects"
run 0 -- --set "$work/set.json" --workers 16 --until preflight
[ "$(runner '.reasons | join(",")')" = dirty_start ] || fail "reasons $(runner .reasons)"
grep -qx wipe "$D/wipe.log" || fail "no wipe"
echo "ok: a dirty start wipes, goes on, and is recorded"

setup
run 1 NO_NVME=1 -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = preflight_failed ] || fail "reasons $(runner .reasons)"
grep -q "cannot read the box facts: nvme_model nvme_size_bytes" "$work/out" || fail "no box facts message"
echo "ok: an unreadable box fact stops preflight"

setup
run 1 DOCKER_HANG=1 FORGE_PERF_CALL_TIMEOUT=1 -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = step_timeout ] || fail "reasons $(runner .reasons)"
[ ! -d "$work/box/mirror" ] || fail "went on after a hung Docker call"
echo "ok: a hung Docker call in preflight stops with step_timeout"

setup
run 1 OLD_SMELT=1 -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = runner_error ] || fail "reasons $(runner .reasons)"
grep -q "does not point piri-0 at s3.us-east-2.amazonaws.com" "$work/out" || fail "no S3 target message"
! grep -q "^docker pull" "$D/docker.log" || fail "pulled before the S3 check"
echo "ok: a smelt that runs piri against in-stack MinIO stops the run"

setup
touch "$D/ssm-down"
run 1 -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = secrets_unavailable ] || fail "reasons $(runner .reasons)"
echo "ok: SSM down stops with secrets_unavailable"

setup
run 1 EXTRA_IMAGE_VAR=HOME -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = runner_error ] || fail "reasons $(runner .reasons)"
grep -q "images outside the pinned set" "$work/out" || fail "no unpinned message"
echo "ok: an image outside the pinned set stops the run"

setup
run 1 UP_EXIT=2 -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = stack_boot_failed ] || fail "reasons $(runner .reasons)"
[ "$(runner .time.stack_up_at)" = null ] || fail "stack_up_at set on a failed boot"
setup
run 1 UP_EXIT=124 -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = step_timeout ] || fail "reasons $(runner .reasons)"
setup
run 1 SETUP_EXIT=1 -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = setup_failed ] || fail "reasons $(runner .reasons)"
echo "ok: boot, timeout and setup failures carry their reasons"

# The poller's pending run: a trigger on a new ingot digest, published as
# calibration while SERIES_LIVE=0.
setup
jq '.images["ghcr.io/fil-forge/ingot:main"] = "sha256:" + ("9" * 64)' "$work/set.json" >"$work/box/state/last-started.json"
jq '{kind: "trigger", set: ., superseded: 2}' "$work/set.json" >"$work/box/state/pending.json"
run 0 -- --workers 16 --until preflight
[ "$(runner '"\(.series) \(.trigger.reason) \(.trigger.changed | join(",")) \(.superseded)"')" = \
  "calibration image ingot 2" ] || fail "trigger $(runner '[.series, .trigger, .superseded]')"
[ ! -e "$work/box/state/pending.json" ] || fail "pending.json left"
echo "ok: a pending trigger runs, names what changed, and publishes as calibration"

setup
echo '{"kind": "trigger"}' >"$work/box/state/pending.json"
run 2 -- --workers 16
[ -e "$work/box/state/pending.json.rejected" ] && [ ! -e "$work/box/state/pending.json" ] || fail "pending not moved aside"
setup
jq '{kind: "trigger", set: (.images |= del(.["ghcr.io/fil-forge/ingot:main"]))}' "$work/set.json" \
  >"$work/box/state/pending.json"
run 2 -- --workers 16
grep -q "no digest for ghcr.io/fil-forge/ingot:main" "$work/out" || fail "no digest message"
[ -e "$work/box/state/pending.json.rejected" ] && [ ! -e "$work/box/state/pending.json" ] || fail "pending not moved aside"
echo "ok: a pending run that cannot start is moved aside"

# Skip mode on a laptop: config/settings/local.env, host checks logged.
setup
run 0 IMDS_DOWN=1 FORGE_PERF_HOST_OPS=skip NTP=no -- --set "$work/set.json" --until preflight
[ "$(runner '"\(.box.instance_type) \(.settings.workers) \(.settings.stop_ingest_at_bytes)"')" = "local 4 2000000000" ] ||
  fail "local settings $(runner .settings)"
grep -q "host-check skipped: sh -c" "$work/out" || fail "clock check not logged as skipped"
echo "ok: skip mode uses the local settings and skips the host checks"
