#!/usr/bin/env bash
# Behavior of run.sh from preflight to the wipe, against stubbed docker, aws,
# make, go, netem.sh, smelt's perf-drill.sh and instance metadata, with real
# git. The stubbed drill writes the record fixtures' valid run. Each case runs in a scratch
# commit of this repository (so `git status` is clean and a hand edit can be
# tested) against local smelt and harness repositories whose history the
# mirrors fetch. The harness commit is reachable only through a pull request
# head, as the pinned one is once its branch is deleted; the smelt commit only
# through a tag, as a pinned one is once its branch is rebuilt.
# shellcheck disable=SC2016,SC2015 # stubs expand their own variables; fail exits
set -euo pipefail

host="$(cd "$(dirname "$0")/.." && pwd -P)"
repo="$(cd "$host/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/run-test.XXXXXX")"
# KEEP_WORK=1 keeps the scratch directory for inspection.
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$work"' EXIT
export D="$work/d" FIXTURES="$host/fixtures"
mkdir -p "$work/bin" "$D"
unset INVOCATION_ID FORGE_PERF_HOST_OPS FORGE_PERF_LOCK_HELD AWS_ENDPOINT_URL AWS_PROFILE
export PYTHONDONTWRITEBYTECODE=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# No background gc or maintenance in the fixture repositories, which setup
# fetches into; a detached gc still writing when the trap runs makes rm fail.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
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
  "image inspect --format"*)
    grep -qxF "${!#}" "$D/images" || exit 1
    case "${!#}" in
      ghcr.io/fil-forge/ingot@*) jq -nc '{"org.opencontainers.image.revision": "b4ec1bb63c5f0eba032262ae1ccb8e673f585c99",
        "org.opencontainers.image.source": "https://github.com/fil-forge/ingot"}' ;;
      *) echo null ;;
    esac ;;
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
  "compose ps -q "*) echo "cid-${!#}" ;;
  # A CPU cap: UPDATE_FAIL fails the update, NANO_WRONG reads back another
  # value. The cap must land after setup and before netem.sh apply.
  "update --cpus"*)
    [ -z "${UPDATE_FAIL:-}" ] || exit 1
    [ ! -e "$D/netem.log" ] && grep -q "^setup " "$D/drill.log" || echo "$*" >>"$D/cap-out-of-order"
    awk -v c="$3" 'BEGIN { printf "%.0f\n", c * 1e9 }' >"$D/nanocpus-${!#}" ;;
  "inspect -f {{.HostConfig.NanoCpus}}"*)
    if [ -n "${NANO_WRONG:-}" ]; then echo 0; else cat "$D/nanocpus-${!#}"; fi ;;
  "inspect -f"*) echo 172.30.0.5 ;;
  "inspect --format"*) echo "/smelt-${!#}-1" ;;
  "logs --timestamps"*)
    printf '%s\n' "2026-10-01T12:00:00Z started" "2026-10-01T12:00:01Z access_key_id: AKIAFAKEKEYID"
    [ -z "${LEAK:-}" ] || echo "2026-10-01T12:00:02Z s3 {fake-secret-value}" ;;
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
      *denylist*) echo zz-no-such-term-zz ;;
      *) exit 254 ;;
    esac ;;
  *" s3 cp "*) [ ! -e "$D/results-down" ] && cp "$3" "$D/raw.tar.zst" ;;
  *" put-object "*)
    [ ! -e "$D/results-down" ] || exit 1
    [ ! -e "$D/record.json" ] || { echo "An error occurred (PreconditionFailed)" >&2; exit 254; }
    while [ "$1" != --body ]; do shift; done
    cp "$2" "$D/record.json" ;;
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
  [ "${UP_EXIT:-0}" != 0 ] || echo cid-ingot >"$D/containers"
  exit "${UP_EXIT:-0}"
fi
STUB
printf '#!/usr/bin/env bash\necho "go $*" >>"$D/go.log"\n' >"$work/bin/go"
printf '#!/usr/bin/env bash\necho "${NTP:-yes}"\n' >"$work/bin/timedatectl"
printf '#!/usr/bin/env bash\n[ "$1" = -u ] && echo 0 || /usr/bin/id "$@"\n' >"$work/bin/id"
for tool in flock modprobe sync sysctl journalctl; do printf '#!/usr/bin/env bash\n' >"$work/bin/$tool"; done
printf '#!/usr/bin/env bash\necho "1.1.1.1 via 10.0.0.1 dev ens5 src 10.0.0.9 uid 0"\n' >"$work/bin/ip"
# Each call reads one more of every allowance counter, so the drill's delta is 1.
cat >"$work/bin/ethtool" <<'STUB'
#!/usr/bin/env bash
echo "ethtool $*" >>"$D/ethtool.log"
n="$(grep -c . "$D/ethtool.log")"
for c in bw_in bw_out pps conntrack linklocal; do echo "     ${c}_allowance_exceeded: $n"; done
STUB
cat >"$work/bin/df" <<'STUB'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/nvme1n1 462000000 1000 ${DF_FREE_KB:-400000000} 1% /mnt/forge-perf/nvme"
STUB
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
# `run` writes a run directory as smelt's does, from the valid fixture, with
# the command line built from the variables run.sh passes. DRILL=no-evidence:
# exit 1 before any evidence. DRILL=hang: run until SIGINT, then record exit 2.
cat >"$work/smelt-src/scripts/perf-drill.sh" <<'STUB'
#!/usr/bin/env bash
# KEEP_OBJECTS DISK_FACTOR PERF_EXTRA_METADATA
echo "$1 INGOT_URL=${INGOT_URL:-unset} AWS_REGION=${AWS_REGION:-unset}" >>"$D/drill.log"
[ "$1" = run ] || exit "${SETUP_EXIT:-0}"
env | grep -E '^(STOP_INGEST_AT|DURATION|WORKERS|LABEL|CONFIG_NOTE|DISK_FACTOR)=' | sort >"$D/drill.env"
runs="$(cd "$(dirname "$0")/.." && pwd)/generated/perf-runs/drill"
dir="$runs/20261001T120455Z-$LABEL"
mkdir -p "$dir/drill" "$dir/logs" "$runs/provider"
echo "SQ_SECRET_KEY=drill-secret-value" >"$runs/provider/.env"
ln -s ../../provider/.env "$dir/drill/.env"
cp "$FIXTURES/valid/run/logs/piri-0.log" "$dir/logs/"
argv=(bin/drill --provider "$dir/drill" --profile "$PROFILE" --stop-ingest-at "$STOP_INGEST_AT" --ramp "$RAMP"
  --window "$WINDOW" --verify-lag-min "$VERIFY_LAG_MIN" --verify-lag-max "$VERIFY_LAG_MAX" --workers "$WORKERS"
  --duration "$DURATION" --rate-target "$RATE_TARGET" "--enforce-floor=$ENFORCE_FLOOR" --progress "$PROGRESS"
  --accounts "$ACCOUNTS" --restore-scale "$RESTORE_SCALE" --config-note "$CONFIG_NOTE")
[ "$KEEP_OBJECTS" != 1 ] || argv+=(--keep-objects)
meta() {
  jq --argjson extra "$PERF_EXTRA_METADATA" --argjson code "$1" \
    --argjson argv "$(printf '%s\0' "${argv[@]}" | jq -Rsc 'split("\u0000")[:-1]')" \
    '.extra = $extra | .images = [] | .suite.argv = $argv | .suite.drill_exit = $code' \
    "$FIXTURES/valid/run/metadata.json" >"$dir/metadata.json"
}
evidence() {
  mkdir -p "$dir/drill/evidence"
  jq --arg sha "$(git -C "$STORAGE_QUALIFICATION_DIR" rev-parse HEAD)" '.provenance.harness_revision = $sha' \
    "$FIXTURES"/valid/run/drill/evidence/drill-*.json >"$dir/drill/evidence/drill-1.json"
}
case "${DRILL:-valid}" in
  valid) meta 0 && evidence ;;
  no-evidence) meta 1 && exit 1 ;;
  hang)
    meta null
    trap 'meta 2; evidence; exit 1' INT
    touch "$D/drill-running"
    while :; do sleep 0.2; done ;;
esac
STUB
chmod +x "$work/smelt-src/scripts/perf-drill.sh"
echo 'PIRI_INDEXER=${PIRI_INDEXER:-on}' >"$work/smelt-src/systems/piri/entrypoint.sh"
git -C "$work/smelt-src" add -A && git -C "$work/smelt-src" commit -qm smelt
git -C "$work/smelt-src" checkout -q -b shakedown
git -C "$work/smelt-src" commit -q --allow-empty -m pinned
smelt_sha="$(git -C "$work/smelt-src" rev-parse HEAD)"
git -C "$work/smelt-src" tag "forge-perf/20261001-${smelt_sha:0:12}"
# A stranger's pull request head, which the smelt mirror must not take.
git -C "$work/smelt-src" commit -q --allow-empty -m stranger
git -C "$work/smelt-src" update-ref refs/pull/7/head HEAD
git -C "$work/smelt-src" checkout -q -
git -C "$work/smelt-src" branch -q -D shakedown
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
mkdir -p "$work/root/sys/class/net/ens5/statistics"
echo 1000 >"$work/root/sys/class/net/ens5/statistics/tx_bytes"

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
  cat >"$work/checkout/scripts/host/wipe.sh" <<'STUB'
#!/usr/bin/env bash
echo wipe >>"$D/wipe.log"
cp "$FORGE_PERF_STATE_DIR/current.json" "$D/current-at-wipe.json" 2>/dev/null || true
rm -f "$D/containers" "$D/volumes" "$D/network" "$D/objects"
STUB
  # netem.sh is tested in netem_test.sh. Here both passes report the valid
  # fixture's numbers; NETEM_POST adds a failed check line to the post pass.
  cat >"$work/checkout/scripts/host/netem.sh" <<'STUB'
#!/usr/bin/env bash
echo "netem $*" >>"$D/netem.log"
echo "${NETEM_LOCAL:-} ${RTT_TOLERANCE_PCT:-}" >"$D/netem.env"
mkdir -p "$NETEM_DIR"
f="$FIXTURES/valid/netem/latency.json"
case "$1 ${2:-}" in
  "verify pre") jq '.post = null' "$f" >"$NETEM_DIR/latency.json" ;;
  "verify post")
    jq --arg r "${NETEM_POST:-}" 'if $r == "" then . else .post.ok = false | .post.reasons = [$r] end' "$f" \
      >"$NETEM_DIR/latency.json"
    [ -z "${NETEM_POST:-}" ] || exit 1 ;;
esac
STUB
  git -C "$work/checkout" init -q
  git -C "$work/checkout" add -A
  git -C "$work/checkout" commit -qm checkout
  printf '%s\n' FORGE_PERF_BOX_ID=main "FORGE_PERF_CHECKOUT=$work/checkout" \
    FORGE_PERF_PIRI_BUCKET_PREFIX=forge-perf-piri-main-1-piri-0- >"$work/box/box.conf"
  jq -n --arg smelt "$smelt_sha" --arg sq "$sq_sha" --argjson images "$images_json" \
    '{smelt: $smelt, harness: {sha: $sq, pinned: true, main: null}, images: $images}' >"$work/set.json"
}

# launch [VAR=value...] -- [run.sh args...]: run.sh in this process, output in $work/out.
launch() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  exec env FORGE_PERF_HARNESS_AUTH=none ${envs[@]+"${envs[@]}"} FORGE_PERF_BOX_CONF="$work/box/box.conf" FORGE_PERF_STATE_DIR="$work/box/state" \
    FORGE_PERF_NVME_MOUNT="$work/box/nvme" FORGE_PERF_RUNTIME="$work/box/run" FORGE_PERF_OUTBOX="$work/box/outbox" \
    FORGE_PERF_MIRRORS="$work/box/mirror" FORGE_PERF_GO_CACHE= FORGE_PERF_HOST_ROOT="$work/root" \
    FORGE_PERF_IMDS_URL=http://imds.test FORGE_PERF_SMELT_URL="$work/smelt-src" \
    FORGE_PERF_HARNESS_URL="$work/sq-src" \
    bash "$work/checkout/scripts/host/run.sh" "$@" >"$work/out" 2>&1
}

# run EXPECTED-STATUS [VAR=value...] -- [run.sh args...]
run() {
  local want="$1" got=0
  shift
  (launch "$@") || got=$?
  [ "$got" = "$want" ] || fail "expected exit $want, got $got"
}

runner() { jq -r "$1" "$work/box/state/runner.json"; }
outcome() { jq -r '.outcome | "\(.class) \(.reasons | join(","))"' "${1:-$D/record.json}"; }
has() { grep -qF -- "$2" "$1" || fail "$1 lacks: $2"; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 has: $2"; }

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
[ "$(runner '.images[] | select(.variable == "INGOT_IMAGE") | "\(.revision) \(.source)"')" = \
  "b4ec1bb63c5f0eba032262ae1ccb8e673f585c99 https://github.com/fil-forge/ingot" ] || fail "ingot labels"
[ "$(runner '[.images[] | select(.variable == "POSTGRES_IMAGE") | .revision, .source] | map(tostring) | join(" ")')" = \
  "null null" ] || fail "postgres labels"
lacks "$D/docker.log" "update --cpus"
echo "ok: a clean run reaches setup with every image pinned; the harness pin comes through a pull ref"

# piri's key reaches compose through the environment only, never the disk.
! grep -rqF -e AKIAFAKEKEYID -e fake-secret-value "$work/box/nvme/work" "$work/box/state" || fail "piri's key on disk"
jq -e '.piri_s3.PIRI_S3_BUCKET_PREFIX == "forge-perf-piri-main-1-piri-0-" and (.services.ingot | keys == ["image"])' \
  "$work/box/nvme/work/run/compose-images.json" >/dev/null || fail "compose-images.json"
echo "ok: piri's key stays off the disk"

# The same run went on through latency, the drill and the post-check, then
# collected, recorded, uploaded and wiped.
rec="$D/record.json"
[ -s "$rec" ] || fail "no record uploaded"
python3 "$repo/scripts/host/schemacheck.py" "$repo/schema/run-record.v1.json" "$rec" >/dev/null || fail "schema"
[ "$(outcome)" = "valid " ] || fail "outcome $(jq -c .outcome "$rec")"
jq -e '.drill.settings.workers == 16 and .drill.results.sustained_windows == 6 and .latency.before.ok and
  .latency.after.ok and .network.allowance_exceeded.bw_in == 1 and .time.drill_finished_at != null' "$rec" >/dev/null ||
  fail "record fields $(jq -c '[.drill.results, .latency.before, .network]' "$rec")"
[ "$(tr '\n' ' ' <"$D/netem.log")" = "netem apply netem verify pre netem verify post " ] || fail "netem calls"
id="$(runner .run_id)"
[ "$(tr '\n' ' ' <"$D/drill.env")" = "CONFIG_NOTE=forge-perf/$id DISK_FACTOR=1.25 DURATION=1h LABEL=$id \
STOP_INGEST_AT=100GB WORKERS=16 " ] || fail "drill env $(cat "$D/drill.env")"
[ "$(grep -n 's3 cp' "$D/aws.log" | cut -d: -f1)" -lt "$(grep -n put-object "$D/aws.log" | cut -d: -f1)" ] ||
  fail "record went up before raw"
[ -z "$(ls -A "$work/box/outbox")" ] || fail "outbox not empty"
zstd -dc "$D/raw.tar.zst" | tar -tf - >"$work/list"
has "$work/list" "./run/netem/latency.json"
has "$work/list" "./perf-runs/drill/20261001T120455Z-$id/metadata.json"
has "$work/list" "./logs/smelt-cid-ingot-1.log"
lacks "$work/list" "provider"
lacks "$work/list" ".env"
zstd -dc "$D/raw.tar.zst" | tar -xOf - >"$work/raw-content"
for secret in AKIAFAKEKEYID fake-secret-value drill-secret-value; do lacks "$work/raw-content" "$secret"; done
[ "$(grep -c . "$D/wipe.log")" = 1 ] && [ "$(jq -r .phase "$D/current-at-wipe.json")" = wiping ] || fail "wipe"
echo "ok: a full run measures, uploads raw then a valid record with no credential in the tarball, and wipes"

# The same record uploaded twice: S3 answers 412, and the outbox clears.
flush() {
  env FORGE_PERF_BOX_CONF="$work/box/box.conf" FORGE_PERF_STATE_DIR="$work/box/state" \
    FORGE_PERF_NVME_MOUNT="$work/box/nvme" FORGE_PERF_RUNTIME="$work/box/run" FORGE_PERF_OUTBOX="$work/box/outbox" \
    FORGE_PERF_HOST_ROOT="$work/root" bash "$work/checkout/scripts/host/outbox.sh" flush >"$work/out" 2>&1
}
cp "$rec" "$work/box/outbox/$id.json"
flush || fail "second upload"
has "$work/out" "record $id was already uploaded"
[ -z "$(ls -A "$work/box/outbox")" ] || fail "outbox not empty after the second upload"
echo "ok: uploading the same record twice clears the outbox both times"

# The runner.json of a clean run is enough for the minimal record, once the
# record step stamps run_finished_at as it does before any build.
echo 'zz-no-such-term-zz' >"$work/deny"
jq '.time.run_finished_at = "2026-10-01T12:00:00Z"' "$work/box/state/runner.json" >"$work/runner-done.json"
python3 "$work/checkout/scripts/host/record.py" minimal --runner "$work/runner-done.json" \
  --denylist "$work/deny" --out "$work/record.json" >/dev/null 2>&1 || fail "record.py minimal on runner.json"
[ "$(jq -r '.box.nvme | "\(.model) \(.size_bytes) \(.filesystem)"' "$work/record.json")" = \
  "Amazon EC2 NVMe Instance Storage 474000000000 ext4" ] || fail "nvme $(jq -c .box.nvme "$work/record.json")"
jq -e '.provenance.images[] | select(.services == ["ingot"]) |
  .revision == "b4ec1bb63c5f0eba032262ae1ccb8e673f585c99" and .source == "https://github.com/fil-forge/ingot"' \
  "$work/record.json" >/dev/null || fail "image labels missing from the minimal record"
echo "ok: a clean run's runner.json makes a minimal record that passes the schema"

refs() { git -C "$work/box/mirror/$1.git" for-each-ref --format='%(refname)' "$2"; }
[ "$(refs smelt refs/tags)" = "refs/tags/forge-perf/20261001-${smelt_sha:0:12}" ] || fail "smelt tags: $(refs smelt refs/tags)"
[ -z "$(refs smelt refs/pull)" ] || fail "the smelt mirror took pull request heads: $(refs smelt refs/pull)"
[ "$(refs storage-qualification refs/pull)" = refs/pull/5/head ] || fail "harness pull refs"
jq -e '.box_id == "main" and (.kernel | type == "string") and (.versions | has("docker"))' \
  "$work/box/nvme/work/run/box-facts.json" >/dev/null || fail "box-facts.json in the run directory"
echo "ok: the smelt pin comes through a tag, smelt's pull heads stay out, and the run keeps box-facts.json"

# A smelt mirror an earlier version filled with pull request heads loses them.
setup
mkdir -p "$work/box/mirror"
git init -q --bare "$work/box/mirror/smelt.git"
git -C "$work/box/mirror/smelt.git" fetch -q "$work/smelt-src" '+refs/pull/*/head:refs/pull/*/head'
run 0 -- --set "$work/set.json" --workers 16 --until preflight
[ -n "$(refs smelt refs/pull)" ] || fail "preflight touched the mirror"
run 0 -- --set "$work/set.json" --workers 16 --until images
[ -z "$(refs smelt refs/pull)" ] || fail "old pull request heads kept: $(refs smelt refs/pull)"
[ "$(git -C "$work/box/mirror/smelt.git" config --get-all remote.origin.fetch | tr '\n' ' ')" = \
  "+refs/heads/*:refs/heads/* +refs/tags/*:refs/tags/* " ] || fail "smelt refspecs"
echo "ok: an existing smelt mirror drops the pull request heads it held"

# Without an override the box uses the GitHub App, whose key is read from SSM.
setup
run 1 FORGE_PERF_HARNESS_AUTH= -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = secrets_unavailable ] || fail "reasons $(runner .reasons)"
grep -q "cannot mint a harness token from the GitHub App key" "$work/out" || fail "no App message"
grep -q "ssm get-parameter --with-decryption --name /forge-perf/harness-app " "$D/aws.log" || fail "App key not read"
! grep -q harness-deploy-key "$D/aws.log" || fail "read the deploy key"
echo "ok: the default harness credential is the GitHub App key in SSM"

setup
run 0 -- --set "$work/set.json" --workers 16 --until images
[ ! -e "$D/make.log" ] || ! grep -q " up$" "$D/make.log" || fail "--until images booted the stack"
[ ! -e "$D/record.json" ] && [ ! -e "$D/wipe.log" ] || fail "--until recorded or wiped"
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
[ "$(outcome)" = "no_data instrument_modified" ] || fail "record $(outcome)"
echo "ok: a hand edit in the checkout stops preflight, and the run is still recorded"

setup
printf '%040d\n' 7 >"$work/box/state/updated-rev"
run 1 -- --set "$work/set.json" --workers 16
[ "$(runner '.reasons | join(",")')" = preflight_failed ] || fail "reasons $(runner .reasons)"
grep -q "update.sh has not completed for this checkout" "$work/out" || fail "no update.sh message"
git -C "$work/checkout" rev-parse HEAD >"$work/box/state/updated-rev"
run 0 -- --set "$work/set.json" --workers 16 --until preflight
echo "ok: preflight stops while update.sh has not completed for the checkout's HEAD"

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
[ "$(outcome)" = "no_data stack_boot_failed" ] || fail "record $(outcome)"
grep -qx wipe "$D/wipe.log" && [ ! -e "$work/box/state/current.json" ] || fail "a failed boot was not wiped"
lacks "$D/netem.log" "netem"
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

# A run the poller dispatched leaves last-run.json, from which the poller
# retries a set an infrastructure failure stopped.
setup
jq '.images["ghcr.io/fil-forge/ingot:main"] = "sha256:" + ("9" * 64)' "$work/set.json" >"$work/box/state/last-started.json"
jq '{kind: "nightly", set: ., superseded: 1, attempt: 2}' "$work/set.json" >"$work/box/state/pending.json"
run 1 UP_EXIT=2 -- --workers 16
jq -e --slurpfile set "$work/set.json" '.kind == "nightly" and .attempt == 2 and .superseded == 1
  and .set.images == $set[0].images and .reasons == ["stack_boot_failed"]
  and .previous_started.images["ghcr.io/fil-forge/ingot:main"] == "sha256:" + ("9" * 64)' \
  "$work/box/state/last-run.json" >/dev/null || fail "last-run $(cat "$work/box/state/last-run.json")"
echo "ok: a dispatched run leaves its set, attempt and reasons for the poller"

setup
jq '{kind: "trigger", set: ., superseded: 0}' "$work/set.json" >"$work/box/state/pending.json"
echo '{"at": "2026-10-01T12:00:00Z"}' >"$work/box/state/hold"
run 0 -- --workers 16
grep -q "the box is held" "$work/out" || fail "no hold message"
[ -e "$work/box/state/pending.json" ] && [ ! -e "$work/box/state/runner.json" ] || fail "a held box started the run"
echo "ok: a pending run that meets the hold waits"

# campaign.sh's runs, on a held box, in the series its pending run names.
for series in "" calibration; do
  setup
  sed 's/^SERIES_LIVE=.*/SERIES_LIVE=1/' "$work/checkout/config/launch.conf" >"$work/launch.conf"
  mv "$work/launch.conf" "$work/checkout/config/launch.conf"
  git -C "$work/checkout" commit -qam live
  jq --arg s "$series" '{kind: "campaign", set: ., superseded: 0, pairing_id: "pair-20261001-t1", workers: "32",
    size: "10GB", duration: "30m"} + (if $s == "" then {} else {series: $s} end)' "$work/set.json" \
    >"$work/box/state/pending.json"
  echo '{"at": "2026-10-01T12:00:00Z"}' >"$work/box/state/hold"
  run 0 -- --until preflight
  [ "$(runner '"\(.series) \(.trigger.reason) \(.pairing_id) \(.settings | "\(.workers) \(.stop_ingest_at_bytes) \(.duration_s)")"')" = \
    "${series:-campaign} pairing pair-20261001-t1 32 10000000000 1800" ] || fail "campaign run $(runner '[.series, .settings]')"
done
echo "ok: a campaign's pending run starts on a held box with its own series, pairing and settings"

# campaign.sh --cap: the caps land on each service's container after setup,
# and the run publishes as calibration with cpu_capped even while live.
capped() {
  setup
  sed 's/^SERIES_LIVE=.*/SERIES_LIVE=1/' "$work/checkout/config/launch.conf" >"$work/launch.conf"
  mv "$work/launch.conf" "$work/checkout/config/launch.conf"
  git -C "$work/checkout" commit -qam live
  jq --argjson caps "$1" '{kind: "campaign", series: "campaign", set: ., superseded: 0, workers: "16", caps: $caps}' \
    "$work/set.json" >"$work/box/state/pending.json"
  echo '{"at": "2026-10-01T12:00:00Z"}' >"$work/box/state/hold"
}
capped '{"ingot": "1.0", "piri-0": "0.5"}'
run 0 --
has "$D/docker.log" "docker update --cpus 1.0 cid-ingot"
has "$D/docker.log" "docker update --cpus 0.5 cid-piri-0"
[ ! -e "$D/cap-out-of-order" ] || fail "a cap was applied outside setup-to-apply: $(cat "$D/cap-out-of-order")"
[ "$(runner '"\(.series) \(.caps | tojson)"')" = 'calibration {"ingot":"1.0","piri-0":"0.5"}' ] ||
  fail "runner $(runner '[.series, .caps]')"
[ "$(jq -r '"\(.series) \(.outcome.class) \(.outcome.flags | join(","))"' "$D/record.json")" = \
  "calibration valid few_windows,nic_allowance_exceeded,cpu_capped" ] || fail "record $(jq -c '[.series, .outcome]' "$D/record.json")"
lacks "$D/record.json" "caps"
lacks "$D/record.json" '"0.5"'
cmp -s "$work/box/nvme/work/run/runner.json" "$work/box/state/runner.json" || fail "the raw bundle's runner.json differs"
echo "ok: a capped run caps each service after setup, stays valid, and publishes as calibration with cpu_capped"

capped '{"ingot": "1.0"}'
run 1 UPDATE_FAIL=1 --
[ "$(runner '.reasons | join(",")')" = runner_error ] || fail "reasons $(runner .reasons)"
grep -q "docker update --cpus 1.0 failed for ingot" "$work/out" || fail "no update message"
[ "$(outcome)" = "no_data runner_error" ] || fail "record $(outcome)"
lacks "$D/netem.log" "netem apply"
grep -qx wipe "$D/wipe.log" || fail "no wipe"
capped '{"ingot": "1.0"}'
run 1 NANO_WRONG=1 --
[ "$(runner '.reasons | join(",")')" = runner_error ] || fail "reasons $(runner .reasons)"
grep -q "ingot has NanoCpus 0 after the update, not 1000000000" "$work/out" || fail "no NanoCpus message"
echo "ok: a cap that fails or does not read back stops the run as no_data runner_error"

for bad in '{"ingot": "0"}' '{"ingot": 1}' '{"Ingot": "1.0"}' '["ingot"]'; do
  capped "$bad"
  run 2 --
  grep -q "pending.json has caps" "$work/out" || fail "caps $bad accepted"
  [ -e "$work/box/state/pending.json.rejected" ] || fail "pending not moved aside for caps $bad"
done
echo "ok: a pending run with malformed caps does not start"

setup
jq '{kind: "nightly", set: ., superseded: 1}' "$work/set.json" >"$work/box/state/pending.json"
echo '{"run_id": "main-1"}' >"$work/box/state/last-run.json"
run 0 -- --set "$work/set.json" --workers 16 --until preflight
[ "$(jq -r .kind "$work/box/state/pending.json")" = nightly ] && [ -e "$work/box/state/last-run.json" ] ||
  fail "a manual run removed the poller's state"
echo "ok: a manual run leaves pending.json and last-run.json"

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
[ "$(runner '"\(.box.instance_type) \(.settings.workers) \(.settings.stop_ingest_at_bytes)"')" = \
  "local.large 4 2000000000" ] ||
  fail "local settings $(runner .settings)"
grep -q "host-check skipped: sh -c" "$work/out" || fail "clock check not logged as skipped"
jq '.time.run_finished_at = "2026-10-01T12:00:00Z"' "$work/box/state/runner.json" >"$work/runner-done.json"
python3 "$work/checkout/scripts/host/record.py" minimal --runner "$work/runner-done.json" \
  --denylist "$work/deny" --out "$work/record.json" >/dev/null 2>&1 || fail "a skip-mode runner.json cannot be recorded"
echo "ok: skip mode uses the local settings, skips the host checks, and can still be recorded"

# ingot killed mid-run: the drill fails before its evidence, the post-check
# finds the container gone.
setup
run 0 DRILL=no-evidence "NETEM_POST=ingot: container cid-ingot is gone" -- --set "$work/set.json" --workers 16
[ "$(outcome)" = "no_data no_evidence,container_restarted" ] || fail "record $(outcome)"
[ "$(jq -r '.outcome.restarted_services | join(",")' "$D/record.json")" = ingot ] || fail "restarted services"
grep -qx wipe "$D/wipe.log" || fail "no wipe"
echo "ok: ingot killed mid-run yields no_data and a wipe"

setup
run 0 DF_FREE_KB=1000 -- --set "$work/set.json" --workers 16
[ "$(outcome)" = "invalid disk_low" ] || fail "record $(outcome)"
echo "ok: free NVMe space under 2 GB makes the run invalid"

setup
run 0 LEAK=1 -- --set "$work/set.json" --workers 16
has "$work/out" "a credential is still in the collected files"
lacks "$D/aws.log" " s3 cp "
jq -e '.outcome.flags | index("raw_missing")' "$D/record.json" >/dev/null || fail "record lacks raw_missing"
echo "ok: piri's secret in a log refuses the raw tarball, and the record says raw_missing"

setup
touch "$D/results-down"
run 0 -- --set "$work/set.json" --workers 16
[ "$(find "$work/box/outbox" -type f | wc -l | tr -d ' ')" = 2 ] || fail "outbox should hold raw and record"
[ ! -e "$work/box/state/current.json" ] && grep -qx wipe "$D/wipe.log" || fail "not wiped with S3 down"
rm "$D/results-down"
flush || fail "flush after S3 came back"
[ -z "$(ls -A "$work/box/outbox")" ] && [ -s "$D/record.json" ] || fail "outbox not flushed"
echo "ok: with S3 down the run wipes and the outbox keeps its files for the next flush"

# A stop request mid-drill: the drill is interrupted and writes its evidence,
# the run is recorded and wiped, and the upload waits for the next poll.
setup
(launch DRILL=hang -- --set "$work/set.json" --workers 16) &
pid=$!
for _ in $(seq 150); do [ ! -e "$D/drill-running" ] || break; sleep 0.2; done
[ -e "$D/drill-running" ] || fail "the drill never started"
kill -TERM "$pid"
got=0
wait "$pid" || got=$?
[ "$got" = 143 ] || fail "expected exit 143 after a stop, got $got"
rec="$(find "$work/box/outbox" -name '*.json')"
[ -n "$rec" ] || fail "no record in the outbox"
[ "$(outcome "$rec")" = "no_data drill_interrupted" ] || fail "record $(outcome "$rec")"
[ "$(jq .outcome.drill_exit "$rec")" = 2 ] || fail "drill exit"
lacks "$D/aws.log" "put-object"
grep -qx wipe "$D/wipe.log" && [ ! -e "$work/box/state/current.json" ] || fail "not wiped after a stop"
echo "ok: a stop mid-drill interrupts the drill, records drill_interrupted and wipes"

setup
run 0 NETEM_LOCAL=1 RTT_TOLERANCE_PCT=40 -- --set "$work/set.json" --workers 16
[ "$(cat "$D/netem.env")" = "1 40" ] || fail "netem.sh saw $(cat "$D/netem.env")"
echo "ok: a local netem tolerance reaches netem.sh"
