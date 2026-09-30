#!/usr/bin/env bash
# check-workflows.sh against workflow fixtures: pinned actions and local ones
# pass; a tag, a short SHA or a SHA without its version comment fails, and so
# does a workflow actionlint rejects.
set -euo pipefail

check="$(cd "$(dirname "$0")/.." && pwd -P)/check-workflows.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/workflows-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  sed 's/^/  | /' "$work/out" >&2 || true
  exit 1
}
run() { # want USES
  local want="$1" got=0
  rm -rf "$work/wf" && mkdir "$work/wf"
  cat >"$work/wf/w.yml" <<YAML
name: w
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-24.04
    steps:
      - uses: $2
YAML
  WORKFLOWS_DIR="$work/wf" bash "$check" >"$work/out" 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "uses: $2 exited $got, wanted $want"
}

sha=3d3c42e5aac5ba805825da76410c181273ba90b1
run 0 "actions/checkout@$sha # v7.0.1"
run 0 "./.github/actions/local"
run 1 "actions/checkout@v7"
run 1 "actions/checkout@${sha:0:12} # v7.0.1"
run 1 "actions/checkout@$sha"
grep -q "not pinned" "$work/out" || fail "unpinned message"
echo "ok: pinned and local actions pass; tags, short SHAs and missing comments fail"

run 1 "actions/checkout@$sha # v7.0.1
        with:
          no-such-input: true
      - run: echo \${{ github.nope.nope }}"
echo "ok: an actionlint error fails"

# GitHub added job.workflow_sha after actionlint 1.7.12; check-workflows.sh
# accepts it and nothing else unknown.
run 0 "actions/checkout@$sha # v7.0.1
        with:
          ref: \${{ job.workflow_sha }}"
echo "ok: job.workflow_sha passes actionlint"

# pr-run.yml runs forge-perf's scripts with the caller's permissions, so it
# checks them out at its own commit, the one the caller pins, never at main.
pr_run="$(cd "$(dirname "$0")/../../.." && pwd -P)/.github/workflows/pr-run.yml"
refs="$(awk '/repository: fil-forge\/forge-perf$/ { want = 1; next } want && /ref:/ { print; want = 0 }' "$pr_run" | sort | uniq -c)"
if [ "$(echo "$refs" | wc -l | tr -d ' ')" != 1 ] || ! echo "$refs" | grep -q "ref: \${{ job.workflow_sha || 'no-job-workflow-sha' }}$"; then
  echo "FAIL: pr-run.yml checks forge-perf out at: $refs" >&2
  exit 1
fi
[ "$(echo "$refs" | awk '{ print $1 }')" -ge 5 ] || { echo "FAIL: fewer than five forge-perf checkouts: $refs" >&2; exit 1; }
echo "ok: pr-run.yml checks forge-perf out at its own commit"

# Comments and reactions go through the issues API, which issues: write
# covers; the one pull request call reads it. No job may ask for more.
if grep -nE '^\s*pull-requests:\s*write' "$pr_run"; then
  echo "FAIL: pr-run.yml asks for pull-requests: write" >&2
  exit 1
fi
echo "ok: pr-run.yml only reads pull requests"
