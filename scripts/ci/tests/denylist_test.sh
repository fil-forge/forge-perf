#!/usr/bin/env bash
# Behavior of check-denylist.sh against a scratch repository and a harmless
# stand-in pattern. The real pattern never appears here.
set -euo pipefail

check="$(cd "$(dirname "$0")/.." && pwd -P)/check-denylist.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/denylist-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

term="zqxjkvw"
pattern_file="$work/pattern"
printf '\n%s\n\n' "Z[Q]XJKVW" >"$pattern_file"

repo="$work/repo"
git init -q -b main "$repo"
cd "$repo"
git config user.name test
git config user.email test@example.invalid
git config commit.gpgsign false
echo clean >file.txt
git add file.txt
git commit -q -m "initial"
first="$(git rev-parse HEAD)"

failures=0
out="$work/out"

# expect <want-status> <description> [VAR=value ...]: run the check in the
# scratch repository with only the given variables set.
expect() {
  local want="$1" what="$2" got=0
  shift 2
  env -u PUBLIC_DENYLIST_REGEX -u DENYLIST_FILE -u DENYLIST_BASE -u DENYLIST_HEAD \
    -u GITHUB_ACTIONS "$@" bash "$check" >"$out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $what: exit $got, want $want"
    sed 's/^/    /' "$out"
    failures=$((failures + 1))
  elif grep -q -i "$term" "$out"; then
    echo "FAIL: $what: output repeats the matched text"
    failures=$((failures + 1))
  else
    echo "ok: $what"
  fi
}

expect 0 "no pattern set skips"
grep -q "skipped" "$out" || { echo "FAIL: skip prints no notice"; failures=$((failures + 1)); }
expect 0 "clean tree and history pass, blank pattern lines ignored" DENYLIST_FILE="$pattern_file"
expect 0 "pattern from the environment" PUBLIC_DENYLIST_REGEX="Z[Q]XJKVW"

echo "a line with ZQXJKVW in it" >untracked.txt
expect 1 "untracked file matches, case-insensitively" DENYLIST_FILE="$pattern_file"
grep -q "untracked.txt:1" "$out" || { echo "FAIL: match not reported by file and line"; failures=$((failures + 1)); }
rm untracked.txt

git commit -q --allow-empty -m "mentions $term"
expect 1 "commit message matches" DENYLIST_FILE="$pattern_file"
expect 0 "commit outside the range passes" DENYLIST_FILE="$pattern_file" \
  DENYLIST_BASE="$(git rev-parse HEAD)" DENYLIST_HEAD=HEAD

base="$(git rev-parse HEAD)"
echo "$term" >>file.txt
git commit -q -am "add a line"
sed -i.bak '$d' file.txt && rm file.txt.bak
git commit -q -am "remove the line"
expect 1 "term added and removed within the range still fails" DENYLIST_FILE="$pattern_file" \
  DENYLIST_BASE="$base" DENYLIST_HEAD=HEAD
expect 1 "all-zero base checks the whole history" DENYLIST_FILE="$pattern_file" \
  DENYLIST_BASE=0000000000000000000000000000000000000000 DENYLIST_HEAD=HEAD
expect 0 "all-zero base on a clean history passes" DENYLIST_FILE="$pattern_file" \
  DENYLIST_BASE=0000000000000000000000000000000000000000 DENYLIST_HEAD="$first"

: >"$work/empty"
expect 2 "an empty pattern is an error" DENYLIST_FILE="$work/empty"

if [ "$failures" -ne 0 ]; then
  echo "denylist_test: $failures failure(s)"
  exit 1
fi
echo "denylist_test: all passed"
