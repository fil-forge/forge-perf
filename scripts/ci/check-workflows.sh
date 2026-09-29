#!/usr/bin/env bash
# Checks the GitHub Actions workflows: actionlint over each, with shellcheck
# over their run steps when shellcheck is on PATH, and every `uses:` of an
# action outside this repository pinned by a full commit SHA with the version
# in a comment. pr-run.yml runs in the service repositories' context, so a
# moving tag there would run whatever the tag points at next.
#
# WORKFLOWS_DIR overrides .github/workflows, which is how the test points it at
# fixtures. CI pins actionlint 1.7.12 in check.yml.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
dir="${WORKFLOWS_DIR:-.github/workflows}"

shopt -s nullglob
files=("$dir"/*.yml "$dir"/*.yaml)
if [ "${#files[@]}" -eq 0 ]; then
  echo "workflows: none under $dir"
  exit 0
fi

# A step's `uses: owner/repo[/path]@ref`, other than a local ./ action or a
# docker:// image, must name a 40-hex commit and carry `# vX...` after it.
unpinned="$(grep -nE '^[[:space:]-]*uses:[[:space:]]' "${files[@]}" \
  | grep -vE 'uses:[[:space:]]+(\./|docker://)' \
  | grep -vE 'uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]' || true)"
if [ -n "$unpinned" ]; then
  echo "workflows: actions not pinned by commit SHA with a version comment:" >&2
  printf '%s\n' "$unpinned" >&2
  exit 1
fi

actionlint -version | sed -n '1s/^/actionlint /p'
actionlint "${files[@]}"
echo "workflows: ${#files[@]} file(s) clean, every action pinned"
