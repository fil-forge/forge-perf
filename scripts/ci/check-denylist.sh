#!/usr/bin/env bash
# Fails when a denied term appears in the tree or in the commits being pushed.
#
# The repository is public and the terms are not, so the pattern lives outside
# it: the repository secret PUBLIC_DENYLIST_REGEX in CI, or a file named by
# DENYLIST_FILE on a laptop. Both hold extended regular expressions, one per
# line, matched without regard to case. With neither set the check prints a
# notice and passes, unless DENYLIST_REQUIRED=true: CI sets that for pushes to
# main and pull requests from this repository, so a missing or renamed secret
# fails there. Only a fork's pull request, which gets no secrets, may skip.
#
# Matches are reported by file and line, or by commit, never by content: the
# CI log of a public repository is public too. A file whose name is denied is
# reported by its position in the file list instead.
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
trap 'rm -f "$patterns" "$patterns.raw" "$scratch" "$scratch.names"' EXIT

if [ -n "${PUBLIC_DENYLIST_REGEX:-}" ]; then
  printf '%s\n' "$PUBLIC_DENYLIST_REGEX" >"$patterns.raw"
elif [ -n "${DENYLIST_FILE:-}" ]; then
  [ -r "$DENYLIST_FILE" ] || { fail "denylist: cannot read DENYLIST_FILE"; exit 2; }
  cp "$DENYLIST_FILE" "$patterns.raw"
elif [ "${DENYLIST_REQUIRED:-}" = "true" ]; then
  fail "denylist: no pattern (PUBLIC_DENYLIST_REGEX or DENYLIST_FILE unset) and DENYLIST_REQUIRED=true"
  exit 2
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

# grep_status <status>: 0 and 1 are a match and no match; anything above is
# an error (a bad pattern, a read failure), which must not pass as clean.
grep_status() {
  if [ "$1" -gt 1 ]; then
    fail "denylist: grep failed"
    exit 2
  fi
}

# File names first, reported by position in the list so the name stays out of
# the log. Tracked files plus untracked ones not ignored, so a file about to be
# added is caught before its commit exists.
git ls-files -z --cached --others --exclude-standard | tr '\0' '\n' >"$scratch.names"
status=0
grep -n -i -E -f "$patterns" "$scratch.names" >"$scratch" || status=$?
grep_status "$status"
if [ "$status" -eq 0 ]; then
  while IFS=: read -r index _; do fail "denylist: denied term in a file name (entry $index of git ls-files)"; done <"$scratch"
  found=1
fi

status=0
git grep -I -i -n -E --untracked -f "$patterns" -- . >"$scratch" || status=$?
grep_status "$status"
if [ "$status" -eq 0 ]; then
  while IFS=: read -r file line _; do
    named=0
    grep -q -i -E -f "$patterns" <<<"$file" || named=$?
    grep_status "$named"
    if [ "$named" -eq 0 ]; then
      fail "denylist: match in a file whose name is denied (line $line)"
    else
      fail "denylist: match at $file:$line"
    fi
  done <"$scratch"
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
  status=0
  grep -q -a -i -E -f "$patterns" "$scratch" || status=$?
  grep_status "$status"
  if [ "$status" -eq 0 ]; then
    fail "denylist: match in commit $commit (message or diff)"
    found=1
  fi
done

if [ "$found" -ne 0 ]; then
  fail "denylist: denied terms found; remove them from the tree and rewrite the commits"
  exit 1
fi
echo "denylist: tree clean; $count commit(s) clean"
