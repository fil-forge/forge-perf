#!/usr/bin/env bash
# Fails when a denied term appears in the tree or in the commits being pushed.
#
# The repository is public and the terms are not, so the pattern lives outside
# it: the repository secret PUBLIC_DENYLIST_REGEX in CI, or a file named by
# DENYLIST_FILE on a laptop. Both hold extended regular expressions, one per
# line, matched without regard to case. With neither set (a fork's pull
# request gets no secrets) the check prints a notice and passes.
#
# Matches are reported by file and line, or by commit, never by content: the
# CI log of a public repository is public too.
#
# Commits: DENYLIST_BASE..DENYLIST_HEAD, each commit's message and diff. CI sets
# both from the event. Locally they default to origin/main..HEAD. A base that is
# empty, all zeros (a new branch) or not in the clone checks all of HEAD's
# history.
set -euo pipefail

notice() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::notice::$*"
  else
    echo "$*"
  fi
}

fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error::$*"
  else
    echo "$*" >&2
  fi
}

patterns="$(mktemp "${TMPDIR:-/tmp}/denylist.XXXXXX")"
scratch="$(mktemp "${TMPDIR:-/tmp}/denylist.XXXXXX")"
trap 'rm -f "$patterns" "$patterns.raw" "$scratch"' EXIT

if [ -n "${PUBLIC_DENYLIST_REGEX:-}" ]; then
  printf '%s\n' "$PUBLIC_DENYLIST_REGEX" >"$patterns.raw"
elif [ -n "${DENYLIST_FILE:-}" ]; then
  [ -r "$DENYLIST_FILE" ] || { fail "denylist: cannot read DENYLIST_FILE"; exit 2; }
  cp "$DENYLIST_FILE" "$patterns.raw"
else
  notice "denylist: no pattern (PUBLIC_DENYLIST_REGEX or DENYLIST_FILE unset); skipped"
  exit 0
fi
# An empty line is a pattern that matches every line, so blank lines go.
grep -v -E '^[[:space:]]*$' "$patterns.raw" >"$patterns" || true
rm -f "$patterns.raw"
if [ ! -s "$patterns" ]; then
  fail "denylist: the pattern is empty"
  exit 2
fi

cd "$(git rev-parse --show-toplevel)"
found=0

# Tracked files plus untracked ones not ignored, so a file about to be added is
# caught before its commit exists.
status=0
git grep -I -i -n -E --untracked -f "$patterns" -- . >"$scratch" || status=$?
if [ "$status" -gt 1 ]; then
  fail "denylist: git grep failed"
  exit 2
fi
if [ "$status" -eq 0 ]; then
  while IFS=: read -r file line _; do fail "denylist: match at $file:$line"; done <"$scratch"
  found=1
fi

head="${DENYLIST_HEAD:-HEAD}"
base="${DENYLIST_BASE-}"
if [ -z "${DENYLIST_BASE+x}" ]; then
  base="$(git rev-parse -q --verify origin/main || true)"
fi
if [ -z "$base" ] || [ -z "${base//0/}" ] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  range=("$head")
else
  range=("$base..$head")
fi

commits="$(git rev-list "${range[@]}")"
count=0
for commit in $commits; do
  count=$((count + 1))
  # The message, then the diff against the first parent, so a merge is judged
  # by what it brings in. Through a file, since `grep -q` closing a pipe early
  # would fail the pipeline under pipefail.
  git show --no-color --no-ext-diff --format=%B --diff-merges=first-parent "$commit" >"$scratch"
  if grep -q -a -i -E -f "$patterns" "$scratch"; then
    fail "denylist: match in commit $commit (message or diff)"
    found=1
  fi
done

if [ "$found" -ne 0 ]; then
  fail "denylist: denied terms found; remove them from the tree and rewrite the commits"
  exit 1
fi
echo "denylist: tree clean; $count commit(s) clean"
