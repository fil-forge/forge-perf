#!/usr/bin/env bash
# Return the box to the state a run starts from.
#
#   wipe.sh [--if-dirty]
#
# In order: `make nuke YES=1` in the smelt checkout; remove every remaining
# container (a leftover Grafana collector, forge-perf-grafana, among them),
# every volume by name and forge-network; empty piri's six buckets and abort
# their incomplete multipart uploads; delete the work tree; check that no
# container or volume remains; fstrim the NVMe; drop the page cache; remove
# images outside the pinned set; delete the secrets under /run, the Grafana
# token file among them.
#
# It never stops Docker, so it can run in a unit ordered after docker.service.
# The NVMe is formatted only at boot (nvme.sh). Every step is safe to repeat,
# so a second wipe changes nothing. --if-dirty returns at once when no
# container, volume, forge-network, work tree or secret is left.
#
# Takes the run lock and waits for it, unless FORGE_PERF_LOCK_HELD is set by
# a caller that holds it (run.sh, recover.sh).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runlib.sh
. "$here/runlib.sh"

if_dirty=false
case "${1:-}" in
  "") ;;
  --if-dirty) if_dirty=true ;;
  *) die "usage: wipe.sh [--if-dirty]" ;;
esac
runner_init

dirty() {
  [ -n "$(stack_containers)" ] || [ -n "$(stack_volumes)" ] ||
    docker network inspect forge-network >/dev/null 2>&1 ||
    [ -n "$(ls -A "$FORGE_PERF_WORK" 2>/dev/null)" ] ||
    [ -e "$FORGE_PERF_RUNTIME/secrets" ] || [ -e "$FORGE_PERF_RUNTIME/aws" ]
}

empty_bucket() {
  local bucket="$1" uploads key id
  if ! piri_aws s3api head-bucket --bucket "$bucket" >/dev/null; then
    host_ops_skipped || die "cannot reach bucket $bucket"
    echo "bucket $bucket not found; skipped"
    return 0
  fi
  piri_aws s3 rm "s3://$bucket" --recursive --only-show-errors
  uploads="$(piri_aws s3api list-multipart-uploads --bucket "$bucket" \
    --query 'Uploads[].[Key,UploadId]' --output text)"
  while IFS=$'\t' read -r key id; do
    [ -n "${id:-}" ] || continue
    piri_aws s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$id"
  done <<<"$uploads"
}

# Digests to keep: config/images.lock and the run's pinned set, which run.sh
# writes to $FORGE_PERF_STATE_DIR/images.pinned. In skip mode only images from
# the pinned ghcr.io/fil-forge/ repositories are candidates for removal, since
# a laptop's other projects share third-party images such as postgres.
prune_images() {
  local pinned id refs keep ref repos
  pinned="$({
    cat "$FORGE_PERF_CHECKOUT/config/images.lock"
    cat "$FORGE_PERF_STATE_DIR/images.pinned" 2>/dev/null || true
  } | sed 's/#.*//')"
  repos="$(tr -s '[:blank:]' '\n' <<<"$pinned" | grep -E '[:/]' | grep -v '^sha256:' |
    sed -E 's/@.*//; s/:[^/:]*$//' | grep '^ghcr\.io/fil-forge/' | sort -u || true)"
  for id in $(docker image ls -q --no-trunc | sort -u); do
    refs="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$id")"
    keep=false
    for ref in $refs; do
      if grep -qwF "${ref#*@}" <<<"$pinned"; then
        keep=true
      elif host_ops_skipped && ! grep -qxF "${ref%@*}" <<<"$repos"; then
        keep=true
      fi
    done
    if host_ops_skipped && [ -z "$refs" ]; then
      keep=true
    fi
    [ "$keep" = true ] || docker image rm -f "$id" >/dev/null || echo "could not remove image $id" >&2
  done
}

if [ "$if_dirty" = true ] && ! dirty; then
  echo "wipe: clean; nothing to do"
  exit 0
fi
take_run_lock
start=$SECONDS

step "smelt make nuke"
smelt="$FORGE_PERF_WORK/smelt"
if [ -f "$smelt/Makefile" ] && [ -f "$smelt/generated/compose/piri.yml" ]; then
  make -C "$smelt" nuke YES=1 || echo "make nuke failed; removing the stack directly" >&2
else
  echo "no smelt checkout with a generated compose model; removing the stack directly"
fi

step "containers, volumes, forge-network"
# IDs and volume names have no spaces, so each list splits on newlines.
ids="$(stack_containers)"
# shellcheck disable=SC2086
[ -z "$ids" ] || docker rm -f $ids >/dev/null
# Compose networks survive when make nuke could not run. No container is left,
# so every user network is unused; skip mode prunes only the project's.
if host_ops_skipped; then
  docker network prune -f --filter "label=com.docker.compose.project=$FORGE_PERF_PROJECT" >/dev/null
else
  docker network prune -f >/dev/null
fi
vols="$(stack_volumes)"
# shellcheck disable=SC2086
[ -z "$vols" ] || docker volume rm $vols >/dev/null || true
if docker network inspect forge-network >/dev/null 2>&1; then
  docker network rm forge-network >/dev/null
fi

step "piri buckets"
if [ -n "${FORGE_PERF_PIRI_BUCKET_PREFIX:-}" ]; then
  for store in $FORGE_PERF_PIRI_STORES; do
    empty_bucket "$FORGE_PERF_PIRI_BUCKET_PREFIX$store"
  done
else
  host_ops_skipped || die "FORGE_PERF_PIRI_BUCKET_PREFIX not set"
  echo "no FORGE_PERF_PIRI_BUCKET_PREFIX; piri keeps its blobs in the stack"
fi

step "work tree"
mkdir -p "$FORGE_PERF_WORK"
find "$FORGE_PERF_WORK" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
left="$(stack_containers)$(stack_volumes)"
[ -z "$left" ] || die "containers or volumes remain after the wipe: $(tr '\n' ' ' <<<"$left")"

step "trim, page cache, images, secrets"
host_op fstrim "$FORGE_PERF_NVME_MOUNT"
host_op sync
host_op sysctl -q vm.drop_caches=3
prune_images
rm -rf "$FORGE_PERF_RUNTIME/secrets" "$FORGE_PERF_RUNTIME/aws"
step "wiped in $((SECONDS - start)) s"
