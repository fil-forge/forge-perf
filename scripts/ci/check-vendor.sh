#!/usr/bin/env bash
# Fails when a file in site/vendor/ differs from the SHA-256 recorded for it in
# site/vendor/VENDOR.md, when a file there has no row, or when a row names a
# file that is missing. The rows are the lines of VENDOR.md's tables whose
# first cell is a file name in backticks and whose last cell is a 64-digit hex
# digest in backticks.
#
# VENDOR_DIR overrides the directory, which is how the tests point it at a
# scratch copy.
set -euo pipefail

if [ -z "${VENDOR_DIR:-}" ]; then
  VENDOR_DIR="$(git rev-parse --show-toplevel)/site/vendor"
fi
manifest="$VENDOR_DIR/VENDOR.md"
[ -r "$manifest" ] || { echo "vendor: cannot read $manifest" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# The backticks are literal Markdown, not command substitution.
# shellcheck disable=SC2016
rows="$(sed -nE 's/^\| `([^`/]+)` \|.*\| `([0-9a-f]{64})` \|[[:space:]]*$/\1 \2/p' "$manifest")"
if [ -z "$rows" ]; then
  echo "vendor: no file rows in $manifest" >&2
  exit 1
fi

status=0
listed=" "
while read -r name want; do
  listed="$listed$name "
  if [ ! -f "$VENDOR_DIR/$name" ]; then
    echo "vendor: $name is listed but missing" >&2
    status=1
    continue
  fi
  got="$(sha256 "$VENDOR_DIR/$name")"
  if [ "$got" != "$want" ]; then
    echo "vendor: $name has SHA-256 $got, VENDOR.md records $want" >&2
    status=1
  fi
done <<<"$rows"

for path in "$VENDOR_DIR"/* "$VENDOR_DIR"/.[!.]*; do
  [ -e "$path" ] || continue
  name="${path##*/}"
  [ "$name" = "VENDOR.md" ] && continue
  case "$listed" in
    *" $name "*) ;;
    *) echo "vendor: $name has no row in VENDOR.md" >&2; status=1 ;;
  esac
done

[ "$status" -eq 0 ] && echo "vendor: $(wc -l <<<"$rows" | tr -d ' ') files match VENDOR.md"
exit "$status"
