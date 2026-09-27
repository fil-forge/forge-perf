#!/usr/bin/env bash
# Writes the set a published run ran, as a committed set file that run.sh
# --set, campaign.sh --set and campaign.yml take.
#
#   scripts/operator/set-from-record.sh <run_id> <file>   (- for stdout)
#
# Reads the record from the results branch, which is public, so it needs no
# credentials: runs/<yyyy>/<mm>/<run_id>.json. FORGE_PERF_RECORDS_URL
# replaces the branch's base URL (a file:// URL in tests). The set carries the
# record's smelt and harness SHAs and the digest of every image in
# config/images.tracked; a record that lacks one of them is refused.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

repo="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
run_id="${1:-}" out="${2:-}"
[ -n "$out" ] || die "usage: set-from-record.sh <run_id> <file>"
[[ "$run_id" =~ ^[a-z0-9]{2,12}-([0-9]{4})([0-9]{2})[0-9]{2}t[0-9]{6}z$ ]] || die "'$run_id' is not a run ID"
base="${FORGE_PERF_RECORDS_URL:-https://raw.githubusercontent.com/fil-forge/forge-perf/results}"
require curl
record="$(curl -fsSL "$base/runs/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/$run_id.json")" ||
  die "no record for $run_id on the results branch"

tracked="$(sed 's/#.*//' "$repo/config/images.tracked" | awk 'NF == 2 { print $2 }' | jq -Rsc 'split("\n") - [""]')"
# shellcheck disable=SC2016 # a jq program
set_json="$(jq -S --argjson tracked "$tracked" '
  (.provenance.images | map({key: "\(.repo):\(.ref)", value: .digest}) | from_entries) as $digests
  | if all($tracked[]; $digests[.] != null) then . else error("an image is missing") end
  | {smelt: .provenance.smelt.sha,
     harness: {sha: .provenance.harness.sha, pinned: true, main: null},
     images: ($tracked | map({key: ., value: $digests[.]}) | from_entries),
     resolved_at: .time.run_started_at}' <<<"$record")" ||
  die "$run_id's record lacks a SHA or a digest for an image in config/images.tracked"

if [ "$out" = - ]; then
  printf '%s\n' "$set_json"
else
  printf '%s\n' "$set_json" >"$out"
  echo "wrote the set of $run_id to $out" >&2
fi
