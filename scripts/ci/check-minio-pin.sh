#!/usr/bin/env bash
# Fails when forge-perf's minio-go differs from piri's. cmd/s3-ceiling measures
# the S3 PUT ceiling through the client piri uses, so the two go.mod files must
# require the same version and neither may replace it.
#
# piri's go.mod comes from PIRI_GO_MOD (a file) or else PIRI_GO_MOD_URL, by
# default piri's main branch on GitHub. OUR_GO_MOD overrides this repository's
# go.mod, which is how the tests point both at fixtures.
set -euo pipefail

module=github.com/minio/minio-go/v7
ours="${OUR_GO_MOD:-$(git rev-parse --show-toplevel)/go.mod}"
url="${PIRI_GO_MOD_URL:-https://raw.githubusercontent.com/fil-forge/piri/main/go.mod}"
if [ -n "${PIRI_GO_MOD:-}" ]; then
  theirs="$(cat "$PIRI_GO_MOD")"
  source="$PIRI_GO_MOD"
else
  theirs="$(curl -fsSL --retry 3 -m 30 "$url")" || { echo "minio-pin: cannot fetch $url" >&2; exit 1; }
  source="$url"
fi

# version GO_MOD_TEXT: the required version, from a one-line require or a
# require block; "replaced" when a replace directive names the module.
version() {
  awk -v m="$module" '
    /^replace[[:space:]]*\(/ { inrep = 1; next }
    inrep && /^\)/ { inrep = 0; next }
    (/^replace[[:space:]]/ || inrep) && index($0, m) { rep = 1; next }
    $1 == "require" && $2 == m { ver = $3 }
    $1 == m { ver = $2 }
    END { print (rep ? "replaced" : ver) }' <<<"$1"
}

want="$(version "$theirs")"
got="$(version "$(cat "$ours")")"
if [ -z "$want" ] || [ "$want" = replaced ]; then
  echo "minio-pin: $source does not require $module plainly (${want:-absent}); compare by hand" >&2
  exit 1
fi
if [ "$got" != "$want" ]; then
  echo "minio-pin: $ours has $module ${got:-absent}, piri has $want; set go.mod to $want and run go mod tidy" >&2
  exit 1
fi
echo "minio-pin: $module $got, as piri"
