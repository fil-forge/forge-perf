#!/usr/bin/env bash
# Behavior of the campaign's operator side: campaign-inputs.sh's checks and
# the variables it prints, reap.sh against a stubbed EC2 listing, and
# set-from-record.sh against a record fixture read through a file:// URL.
# SC2016: stub bodies and jq programs expand later, not here.
# shellcheck disable=SC2016
set -euo pipefail

repo="$(cd "$(dirname "$0")/../../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/campaign-ops-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# A copy of the files the scripts read, so a test set can be added to it.
tree="$work/tree" ops="$work/tree/scripts/operator"
mkdir -p "$tree/scripts" "$tree/calibration" "$tree/terraform/envs/box/main"
cp -R "$repo/scripts/operator" "$tree/scripts/"
cp -R "$repo/config" "$tree/"
cp -R "$repo/calibration/sets" "$tree/calibration/"
cp "$repo/terraform/envs/box/main/terraform.tfvars" "$tree/terraform/envs/box/main/"
export WORK="$work"

cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$WORK/aws.log"
case "$2" in
  describe-instances) cat "$WORK/instances.json" ;;
  terminate-instances) ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/aws"
export PATH="$work/bin:$PATH"

fail() {
  echo "FAIL: $*" >&2
  sed 's/^/  | /' "$work/out" >&2 || true
  exit 1
}

# --- campaign-inputs.sh ------------------------------------------------------------

sha=0123456789abcdef0123456789abcdef01234567
inputs() {
  local want="$1" got=0
  shift
  env INSTANCE_TYPE=m9gd.2xlarge HOURS=2 MODE=campaign SET=calibration/sets/shakedown.json RUNS=1 SIZE=10GB \
    WORKERS=16 DURATION=30m FORGE_PERF_SHA="$sha" NOW=1790000000 "$@" \
    bash "$ops/campaign-inputs.sh" >"$work/out" 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "campaign-inputs.sh $* exited $got, wanted $want"
}

inputs 0
jq -e --arg sha "$sha" '. == {instance_type: "m9gd.2xlarge", expires_at: "2026-09-21T16:13:20Z", forge_perf_sha: $sha,
  campaign: {mode: "campaign", set: "calibration/sets/shakedown.json", runs: 1, size: "10GB", workers: [16],
  duration: "30m"}}' "$work/out" >/dev/null || fail "variables"
inputs 0 WORKERS="16, 32,64"
[ "$(jq -c .campaign.workers "$work/out")" = "[16,32,64]" ] || fail "a workers list"
inputs 1 WORKERS=
grep -q "has no WORKERS yet" "$work/out" || fail "no workers, and none in the settings file"
sed 's/^WORKERS=$/WORKERS=32/' "$repo/config/settings/m9gd.2xlarge.env" >"$tree/config/settings/m9gd.2xlarge.env"
inputs 0 WORKERS=
[ "$(jq -c .campaign.workers "$work/out")" = "[]" ] || fail "no workers"
inputs 0 DURATION=240m
inputs 0 MODE=calibration SET= INSTANCE_TYPE=m9gd.16xlarge
echo "ok: the acceptance dispatch, a sweep, the settings file's workers and a calibration box pass"

for bad in HOURS=0 HOURS=25 HOURS=2h INSTANCE_TYPE=m7i.large MODE=other RUNS=0 RUNS=21 SIZE=10G \
  SIZE='10GB;x' DURATION=30 DURATION=5h DURATION=241m WORKERS=0 WORKERS=16,16 WORKERS=2000 WORKERS='16;id' SET=calibration/sets/none.json \
  SET=../config/images.lock INSTANCE_TYPE=m9gd.16xlarge FORGE_PERF_SHA=main; do
  inputs 1 "$bad"
done
jq '.images = {}' "$tree/calibration/sets/shakedown.json" >"$tree/calibration/sets/partial.json"
inputs 1 SET=calibration/sets/partial.json
grep -q "digest for every image" "$work/out" || fail "a set without digests"
echo "ok: hours 0 and 25, a type without settings, a missing or partial set, a run over 4h and malformed values are refused"

# --- reap.sh ------------------------------------------------------------------------------

now=1790000000 # 2026-09-21T14:13:20Z
instance() { # id box state type expires reason
  jq -n --arg id "$1" --arg box "$2" --arg state "$3" --arg type "$4" --arg exp "$5" --arg reason "$6" \
    '{id: $id, type: $type, state: $state, reason: $reason,
      tags: ([{Key: "Project", Value: "forge-perf"}, {Key: "Box", Value: $box}]
        + (if $exp == "" then [] else [{Key: "ExpiresAt", Value: $exp}] end))}'
}
{
  instance i-main main running m9gd.2xlarge "" ""
  instance i-live campaign running m9gd.16xlarge 2026-09-21T18:00:00Z ""
  instance i-scratch-old scratch running m9gd.2xlarge 2026-09-21T13:00:00Z ""
  instance i-closing campaign stopping m9gd.2xlarge 2026-09-21T14:00:00Z ""
  instance i-scratch-new scratch running m9gd.2xlarge 2026-09-21T20:00:00Z ""
} | jq -s . >"$work/instances.json"
rm -f "$work/aws.log"
NOW="$now" GITHUB_OUTPUT="$work/gh" bash "$ops/reap.sh" >"$work/out" 2>&1 || fail "reap.sh failed"
grep -q "terminate-instances .*--instance-ids i-scratch-old --output" "$work/aws.log" || fail "the expired scratch box"
grep -q "Project,Values=forge-perf .*pending,running,stopping,stopped" "$work/aws.log" || fail "the filter"
grep -qx "campaign=false" "$work/gh" && [ "$(wc -l <"$work/out" | tr -d ' ')" = 1 ] || fail "only one to reap"
grep -q i-closing "$work/out" && fail "a box shutting down at its ExpiresAt was reaped"
echo "ok: a scratch box an hour past ExpiresAt is terminated; one shutting down at ExpiresAt, a live box and main stay"

{
  instance i-main main running m9gd.8xlarge "" ""
  instance i-done campaign stopped m9gd.2xlarge 2026-09-21T18:00:00Z "User initiated (2026-09-21 13:00:00 GMT)"
  instance i-recent campaign stopped m9gd.2xlarge 2026-09-21T18:00:00Z "User initiated (2026-09-21 13:50:00 GMT)"
  instance i-untagged other pending m9gd.2xlarge "" ""
} | jq -s . >"$work/instances.json"
rm -f "$work/aws.log" "$work/gh"
NOW="$now" GITHUB_OUTPUT="$work/gh" bash "$ops/reap.sh" >"$work/out" 2>&1 || fail "reap.sh failed"
grep -qx "campaign=true" "$work/gh" || fail "the stopped campaign box is not destroyed"
grep -q "terminating and destroying the campaign box i-done: it has been stopped for over an hour" "$work/out" ||
  fail "stopped"
grep -q "i-recent" "$work/out" && fail "a box stopped 23 minutes ago"
grep -q "terminate-instances .*--instance-ids i-done i-untagged --output" "$work/aws.log" ||
  fail "the campaign box, which its state may not hold, and a box without ExpiresAt"
grep -q "persistent box" "$work/out" && fail "type drift reported outside the 00:00 UTC hour"
grep -q "i-main" "$work/aws.log" && fail "the persistent box was touched"
rm -f "$work/gh"
NOW=$((now - 14 * 3600)) GITHUB_OUTPUT="$work/gh" bash "$ops/reap.sh" >"$work/out" 2>&1 || fail "reap.sh failed"
grep -q "the persistent box is m9gd.8xlarge; terraform.tfvars says m9gd.2xlarge" "$work/gh" || fail "type drift"
REPORT_DRIFT=1 NOW="$now" bash "$ops/reap.sh" >"$work/out" 2>&1 || fail "reap.sh failed"
grep -q "the persistent box is m9gd.8xlarge" "$work/out" || fail "type drift with REPORT_DRIFT=1"
echo "ok: a campaign box stopped over an hour is terminated and destroyed; main's type drift is reported once a day"

# --- set-from-record.sh ---------------------------------------------------------------------

record="$repo/scripts/host/fixtures/valid/expected.json"
run_id="$(jq -r .run_id "$record")"
mkdir -p "$work/results/runs/${run_id:5:4}/${run_id:9:2}"
cp "$record" "$work/results/runs/${run_id:5:4}/${run_id:9:2}/$run_id.json"
FORGE_PERF_RECORDS_URL="file://$work/results" bash "$ops/set-from-record.sh" "$run_id" "$work/set.json" \
  >"$work/out" 2>&1 || fail "set-from-record.sh failed"
tracked="$(sed 's/#.*//' "$repo/config/images.tracked" | awk 'NF == 2 { print $2 }' | jq -Rsc 'split("\n") - [""]')"
jq -e --argjson tracked "$tracked" --slurpfile r "$record" '
  .smelt == $r[0].provenance.smelt.sha and .harness == {sha: $r[0].provenance.harness.sha, pinned: true, main: null}
  and (.images | keys) == ($tracked | sort) and .resolved_at == $r[0].time.run_started_at
  and .images["ghcr.io/fil-forge/ingot:main"] ==
    ($r[0].provenance.images[] | select(.repo == "ghcr.io/fil-forge/ingot") | .digest)' "$work/set.json" >/dev/null ||
  fail "set $(cat "$work/set.json")"
jq '.provenance.images |= map(select(.repo != "ghcr.io/fil-forge/piri"))' "$record" \
  >"$work/results/runs/${run_id:5:4}/${run_id:9:2}/$run_id.json"
FORGE_PERF_RECORDS_URL="file://$work/results" bash "$ops/set-from-record.sh" "$run_id" - >"$work/out" 2>&1 &&
  fail "a record without piri's digest made a set"
bash "$ops/set-from-record.sh" not-a-run - >"$work/out" 2>&1 && fail "a malformed run ID"
echo "ok: set-from-record.sh writes the record's SHAs and tracked digests, and refuses a partial record"

echo "campaign ops: all tests passed"
