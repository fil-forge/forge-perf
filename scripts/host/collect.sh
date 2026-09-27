#!/usr/bin/env bash
# Build a run's raw tarball, the private copy of what the run left behind.
#
#   collect.sh OUT FORBID NAME=DIR...
#
# Copies each DIR that exists to NAME/ in a stage under the work tree, leaving
# out every *.env file and every provider/ directory, which hold the drill's
# key (smelt links drill/.env to provider/.env). Adds `docker logs
# --timestamps` of every stack container as logs/<container>.log, and drops
# every line that names access_key_id or secret_access_key, which `piri init`
# prints. Then it looks for each line of FORBID (piri's key ID and secret, the
# harness credential) in the staged files as a literal string, and writes OUT,
# a zstd tarball, only when none appears.
#
# Exit status: 0 OUT written; 3 no OUT, because FORBID is missing or empty or
# one of its strings is in the files; 1 any other failure. The stage and any
# partial OUT are removed either way.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

[ $# -ge 2 ] || die "usage: collect.sh OUT FORBID NAME=DIR..."
out="$1" forbid="$2"
shift 2
runner_init
stage="$FORGE_PERF_WORK/raw-stage"
trap 'rm -rf "$stage" "$out.tmp"' EXIT

rm -rf "$stage"
mkdir -p "$stage/logs"
for pair; do
  name="${pair%%=*}" dir="${pair#*=}"
  [ -d "$dir" ] || continue
  mkdir -p "$stage/$name"
  tar -C "$dir" --exclude '*.env' --exclude provider -cf - . | tar -C "$stage/$name" -xf -
done
for id in $(stack_containers); do
  name="$(docker inspect --format '{{.Name}}' "$id")" || name="$id"
  docker logs --timestamps "$id" >"$stage/logs/${name#/}.log" 2>&1 || true
done
while IFS= read -r -d '' f; do
  status=0
  LC_ALL=C grep -a -viE 'access_key_id|secret_access_key' "$f" >"$f.scrub" || status=$?
  [ "$status" -le 1 ] || exit 1
  mv "$f.scrub" "$f"
done < <(find "$stage" -type f -print0)

if [ ! -s "$forbid" ]; then
  echo "collect: without the credentials to check against, no raw tarball" >&2
  exit 3
fi
if LC_ALL=C grep -rqaF -f "$forbid" "$stage"; then
  echo "collect: a credential is still in the collected files; no raw tarball" >&2
  exit 3
fi
tar -C "$stage" -cf - . | zstd -q -f -o "$out.tmp"
mv "$out.tmp" "$out"
echo "collect: wrote $out"
