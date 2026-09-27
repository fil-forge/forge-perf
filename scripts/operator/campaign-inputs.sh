#!/usr/bin/env bash
# Checks campaign.yml's inputs and prints the campaign root's variables as
# JSON, for `tofu apply -var-file`. Reads the inputs from the environment, so
# no input is ever expanded into a shell command:
#
#   INSTANCE_TYPE HOURS MODE SET RUNS SIZE WORKERS DURATION FORGE_PERF_SHA
#
# HOURS is 1 to 24. WORKERS is empty (the settings file's value), one number,
# or a comma list that the box sweeps (docs/operations.md, "A campaign"). In
# mode campaign, SET must be a committed set under calibration/sets/ with a
# digest for every tracked image, and config/settings/<INSTANCE_TYPE>.env
# must exist, since run.sh refuses a type without one, and an empty WORKERS
# needs a WORKERS value in it. DURATION is at most 4h, so a run and its
# record fit in forge-perf-run.service's 6-hour limit. In mode campaign the
# runs must fit in HOURS at their longest: 30 minutes to boot and provision,
# then each run's duration plus 45 minutes for setup, record and wipe, since a
# run still going at ExpiresAt is cut by the box's poweroff. NOW (Unix seconds)
# replaces the clock in tests.
set -euo pipefail

die() {
  echo "campaign: $*" >&2
  exit 1
}

repo="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
now="${NOW:-$(date -u +%s)}"

case "${INSTANCE_TYPE:-}" in
  m9gd.2xlarge | m9gd.8xlarge | m9gd.16xlarge) ;;
  *) die "instance_type '${INSTANCE_TYPE:-}' is not one of the tiers' types" ;;
esac
[[ "${HOURS:-}" =~ ^[0-9]+$ ]] && [ "$HOURS" -ge 1 ] && [ "$HOURS" -le 24 ] || die "hours takes 1 to 24"
[[ "${FORGE_PERF_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "FORGE_PERF_SHA is not a full commit"
case "${MODE:-}" in
  campaign | calibration) ;;
  *) die "mode is campaign or calibration" ;;
esac
[[ "${RUNS:-}" =~ ^[1-9][0-9]*$ ]] && [ "$RUNS" -le 20 ] || die "runs takes 1 to 20"
[[ "${SIZE:-}" =~ ^[1-9][0-9]*GB$ ]] || die "size is a whole number of GB, like 100GB"
[[ "${DURATION:-}" =~ ^([1-9][0-9]{0,5})([smh])$ ]] || die "duration is like 30m or 4h"
case "${BASH_REMATCH[2]}" in
  s) duration_s="${BASH_REMATCH[1]}" ;;
  m) duration_s=$((BASH_REMATCH[1] * 60)) ;;
  h) duration_s=$((BASH_REMATCH[1] * 3600)) ;;
esac
[ "$duration_s" -le 14400 ] || die "duration is at most 4h, so the run fits in forge-perf-run.service's 6 hours"
workers="${WORKERS:-}"
workers="${workers// /}"
[[ -z "$workers" || "$workers" =~ ^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3}){0,7}$ ]] ||
  die "workers is empty, one number or up to 8 comma-separated numbers"
workers_json="$(jq -c 'split(",") - [""] | map(tonumber)' <<<"\"$workers\"")"
jq -e 'all(. <= 1024) and (unique | length) == length' <<<"$workers_json" >/dev/null ||
  die "each workers value is 1024 or less, and none repeats"

set_path="${SET:-}"
if [ "$MODE" = campaign ]; then
  [[ "$set_path" =~ ^calibration/sets/[A-Za-z0-9._-]+\.json$ ]] || die "set is a file under calibration/sets/"
  [ -f "$repo/$set_path" ] || die "$set_path is not in this commit"
  tracked="$(sed 's/#.*//' "$repo/config/images.tracked" | awk 'NF == 2 { print $2 }' | jq -Rsc 'split("\n") - [""]')"
  jq -e --argjson tracked "$tracked" '
    (.smelt // "" | test("^[0-9a-f]{40}$")) and (.harness.sha // "" | test("^[0-9a-f]{40}$")) and
    all($tracked[] as $r | .images[$r] // ""; test("^sha256:[0-9a-f]{64}$"))' "$repo/$set_path" >/dev/null 2>&1 ||
    die "$set_path needs a smelt SHA, a harness SHA and a digest for every image in config/images.tracked"
  [ -f "$repo/config/settings/$INSTANCE_TYPE.env" ] ||
    die "no config/settings/$INSTANCE_TYPE.env; run.sh would refuse every run on this type"
  [ -n "$workers" ] || grep -qE '^WORKERS=[1-9]' "$repo/config/settings/$INSTANCE_TYPE.env" ||
    die "config/settings/$INSTANCE_TYPE.env has no WORKERS yet; give workers, one number or a list to sweep"
  per_round="$(jq 'if length == 0 then 1 else length end' <<<"$workers_json")"
  need=$((1800 + RUNS * per_round * (duration_s + 2700)))
  [ "$need" -le $((HOURS * 3600)) ] ||
    die "$((RUNS * per_round)) run(s) of $DURATION need up to $(((need + 3599) / 3600)) hours; hours is $HOURS"
fi

at=$((now + HOURS * 3600))
expires="$(date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg type "$INSTANCE_TYPE" --arg expires "$expires" --arg sha "$FORGE_PERF_SHA" --arg mode "$MODE" \
  --arg set "$set_path" --argjson runs "$RUNS" --arg size "$SIZE" --argjson workers "$workers_json" \
  --arg duration "$DURATION" '
  {instance_type: $type, expires_at: $expires, forge_perf_sha: $sha,
   campaign: {mode: $mode, set: $set, runs: $runs, size: $size, workers: $workers, duration: $duration}}'
