#!/usr/bin/env bash
# check-minio-pin.sh against go.mod fixtures: the same version passes; a
# different, missing or replaced one fails.
set -euo pipefail

check="$(cd "$(dirname "$0")/.." && pwd -P)/check-minio-pin.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/minio-pin-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  sed 's/^/  | /' "$work/out" >&2 || true
  exit 1
}
pin() { # want OURS THEIRS
  local want="$1" got=0
  OUR_GO_MOD="$2" PIRI_GO_MOD="$3" bash "$check" >"$work/out" 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "check-minio-pin.sh $2 $3 exited $got, wanted $want"
}
mod() { # name body
  printf 'module example.com/%s\n\ngo 1.25.0\n\n%s\n' "$1" "$2" >"$work/$1"
}

mod ours 'require github.com/minio/minio-go/v7 v7.3.0'
mod piri 'require (
	github.com/ipfs/go-cid v0.5.0
	github.com/minio/minio-go/v7 v7.3.0
)'
pin 0 "$work/ours" "$work/piri"
grep -q "minio-go/v7 v7.3.0, as piri" "$work/out" || fail "message"
mod newer 'require (
	github.com/minio/minio-go/v7 v7.3.1
)'
pin 1 "$work/ours" "$work/newer"
grep -q "piri has v7.3.1" "$work/out" || fail "mismatch message"
mod none 'require github.com/ipfs/go-cid v0.5.0'
pin 1 "$work/ours" "$work/none"
pin 1 "$work/none" "$work/piri"
mod replaced 'require github.com/minio/minio-go/v7 v7.3.0

replace (
	github.com/minio/minio-go/v7 => ../minio-go
)'
pin 1 "$work/ours" "$work/replaced"
grep -q "compare by hand" "$work/out" || fail "replace message"
echo "ok: the same pin passes; a different, missing or replaced one fails"

pin 0 "$(cd "$(dirname "$0")/../../.." && pwd -P)/go.mod" "$work/piri"
echo "ok: this repository's go.mod pins v7.3.0"
