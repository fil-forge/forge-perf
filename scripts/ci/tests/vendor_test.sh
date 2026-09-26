#!/usr/bin/env bash
# Behavior of check-vendor.sh against scratch copies of a vendor directory.
set -euo pipefail

check="$(cd "$(dirname "$0")/.." && pwd -P)/check-vendor.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/vendor-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# The backticks in fresh() are literal Markdown.
# shellcheck disable=SC2016
# fresh <dir>: a vendor directory with two files and a VENDOR.md that lists
# both, including a package table whose rows the check must ignore.
fresh() {
  rm -rf "$1"
  mkdir -p "$1"
  printf 'lib a\n' >"$1/a.js"
  printf 'license a\n' >"$1/LICENSE.a"
  {
    echo '| Package | Version | License | Tarball | npm integrity |'
    echo '|---|---|---|---|---|'
    echo '| `a` | 1.0.0 | ISC | https://example.invalid/a.tgz | `sha512-x` |'
    echo
    echo '| File | Package path | SHA-256 |'
    echo '|---|---|---|'
    echo "| \`a.js\` | \`a/dist/a.js\` | \`$(sha256 "$1/a.js")\` |"
    echo "| \`LICENSE.a\` | \`a/LICENSE\` | \`$(sha256 "$1/LICENSE.a")\` |"
  } >"$1/VENDOR.md"
}

failures=0
out="$work/out"

# expect <want-status> <description> <dir> [grep pattern for the output]
expect() {
  local want="$1" what="$2" dir="$3" pattern="${4:-}" got=0
  VENDOR_DIR="$dir" bash "$check" >"$out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $what: exit $got, want $want"
    sed 's/^/    /' "$out"
    failures=$((failures + 1))
  elif [ -n "$pattern" ] && ! grep -q -- "$pattern" "$out"; then
    echo "FAIL: $what: output lacks '$pattern'"
    sed 's/^/    /' "$out"
    failures=$((failures + 1))
  else
    echo "ok: $what"
  fi
}

dir="$work/vendor"

fresh "$dir"
expect 0 "matching files pass" "$dir" "2 files match"

fresh "$dir"
printf 'tampered\n' >>"$dir/a.js"
expect 1 "a changed file fails" "$dir" "a.js has SHA-256"

fresh "$dir"
printf 'extra\n' >"$dir/b.js"
expect 1 "an unlisted file fails" "$dir" "b.js has no row"

fresh "$dir"
printf 'hidden\n' >"$dir/.extra"
expect 1 "an unlisted dotfile fails" "$dir" ".extra has no row"

fresh "$dir"
rm "$dir/LICENSE.a"
expect 1 "a listed file that is missing fails" "$dir" "LICENSE.a is listed but missing"

fresh "$dir"
# shellcheck disable=SC2016
grep -v 'SHA-256\|`[0-9a-f]\{64\}`' "$dir/VENDOR.md" >"$work/md"
mv "$work/md" "$dir/VENDOR.md"
expect 1 "a VENDOR.md without file rows fails" "$dir" "no file rows"

fresh "$dir"
rm "$dir/VENDOR.md"
expect 1 "a missing VENDOR.md fails" "$dir" "cannot read"

if [ "$failures" -ne 0 ]; then
  echo "$failures vendor check test(s) failed"
  exit 1
fi
