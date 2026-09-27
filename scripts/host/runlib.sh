# Helpers for the run-side host scripts (wipe.sh, recover.sh, outbox.sh):
# the box's paths, the run lock, the stack's Docker objects and the AWS CLI
# calls against piri's buckets. Sourced after lib.sh, never executed.
#
# In skip mode (FORGE_PERF_HOST_OPS=skip, a laptop running Docker Desktop) the
# Docker selectors narrow to the smelt stack and forge-perf's own containers,
# so a local wipe leaves the laptop's other containers, volumes and images
# alone. On the box, which runs nothing else, they select everything.

# shellcheck shell=bash

# shellcheck disable=SC2034 # used by wipe.sh
FORGE_PERF_PIRI_STORES="allocations acceptances claims receipts pdp consolidation"
FORGE_PERF_PROJECT="${COMPOSE_PROJECT_NAME:-smelt}"

# Load box.conf and the S3 settings, and set the run paths. A variable box.conf
# sets overrides the environment's value; either overrides the defaults below.
runner_init() {
  local conf="${FORGE_PERF_BOX_CONF:-/etc/forge-perf/box.conf}"
  host_ops_skipped || [ "$(id -u)" -eq 0 ] || die "must run as root"
  [ -r "$conf" ] || die "$conf is missing; cloud-init did not finish"
  # shellcheck disable=SC1090
  . "$conf"
  refuse_skip_on_box
  : "${FORGE_PERF_BOX_ID:?FORGE_PERF_BOX_ID not set in $conf}"
  FORGE_PERF_CHECKOUT="${FORGE_PERF_CHECKOUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
  FORGE_PERF_WORK="${FORGE_PERF_WORK:-$FORGE_PERF_NVME_MOUNT/work}"
  FORGE_PERF_OUTBOX="${FORGE_PERF_OUTBOX:-/var/lib/forge-perf/outbox}"
  FORGE_PERF_RUNTIME="${FORGE_PERF_RUNTIME:-/run/forge-perf}"
  # shellcheck source=../../config/piri-s3.env
  . "$FORGE_PERF_CHECKOUT/config/piri-s3.env"
}

# Take the run lock on descriptor 9 and wait for it, unless the caller already
# holds it (run.sh exports FORGE_PERF_LOCK_HELD=1 to the wipe it starts).
take_run_lock() {
  [ -z "${FORGE_PERF_LOCK_HELD:-}" ] || return 0
  mkdir -p "$FORGE_PERF_RUNTIME"
  exec 9>"$FORGE_PERF_RUNTIME/run.lock"
  if command -v flock >/dev/null; then
    flock 9
  elif host_ops_skipped; then
    echo "flock is not installed here; the run lock is not taken" >&2
  else
    die "flock is missing"
  fi
  export FORGE_PERF_LOCK_HELD=1
}

# write_durable FILE < content: replace FILE through a temporary file, with
# the file and its directory synced, so a reboot leaves the old or the new
# content (current.json).
write_durable() {
  python3 -c '
import os, sys
dest = sys.argv[1]
tmp = dest + ".tmp"
with open(tmp, "wb") as f:
    f.write(sys.stdin.buffer.read())
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, dest)
fd = os.open(os.path.dirname(os.path.abspath(dest)), os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)' "$1"
}

stack_containers() {
  if host_ops_skipped; then
    {
      docker ps -aq --filter "label=com.docker.compose.project=$FORGE_PERF_PROJECT"
      docker ps -aq --filter name=^smeltery-
      docker ps -aq --filter name=^forge-perf-
    } | sort -u
  else
    docker ps -aq
  fi
}

stack_volumes() {
  if host_ops_skipped; then
    {
      docker volume ls -q --filter "label=com.docker.compose.project=$FORGE_PERF_PROJECT"
      docker volume ls -q | grep "^${FORGE_PERF_PROJECT}_" || true
    } | sort -u
  else
    docker volume ls -q
  fi
}

# The AWS CLI against piri's buckets, at the endpoint, TLS setting and
# credentials config/piri-s3.env names.
piri_aws() {
  local url="$FORGE_PERF_PIRI_S3_HOST_URL" scheme=https
  if [ -z "$url" ]; then
    [ "$FORGE_PERF_PIRI_S3_INSECURE" != true ] || scheme=http
    url="$scheme://$FORGE_PERF_PIRI_S3_ENDPOINT"
  fi
  set -- --endpoint-url "$url" --region "$FORGE_PERF_PIRI_S3_REGION" "$@"
  [ -z "$FORGE_PERF_PIRI_S3_CA_BUNDLE" ] || set -- --ca-bundle "$FORGE_PERF_PIRI_S3_CA_BUNDLE" "$@"
  case "$FORGE_PERF_PIRI_S3_HOST_AUTH" in
    role) aws "$@" ;;
    key)
      (
        # shellcheck disable=SC1090
        . "$FORGE_PERF_PIRI_S3_CREDENTIALS"
        [ -n "${FORGE_PERF_PIRI_S3_KEY_ID:-}" ] && [ -n "${FORGE_PERF_PIRI_S3_SECRET:-}" ] ||
          die "$FORGE_PERF_PIRI_S3_CREDENTIALS lacks FORGE_PERF_PIRI_S3_KEY_ID or FORGE_PERF_PIRI_S3_SECRET"
        AWS_ACCESS_KEY_ID="$FORGE_PERF_PIRI_S3_KEY_ID" AWS_SECRET_ACCESS_KEY="$FORGE_PERF_PIRI_S3_SECRET" \
          AWS_SESSION_TOKEN='' aws "$@"
      )
      ;;
    *) die "FORGE_PERF_PIRI_S3_HOST_AUTH must be role or key" ;;
  esac
}

ssm_value() {
  aws ssm get-parameter --with-decryption --name "$1" --query Parameter.Value --output text
}

# harness_git DIR: how git reaches the harness repository, in HARNESS_GIT (a
# command prefix) and HARNESS_URL, with the credential written under DIR.
# SQ_AUTH in config/harness.conf, or FORGE_PERF_HARNESS_AUTH for a local run:
# deploy-key (an SSH key in SSM), app (a GitHub App installation token minted
# from the App's key in SSM) or none (the caller's own git credentials).
# Returns 1 when the credential cannot be read, 2 for an unknown SQ_AUTH. The
# caller defines `limited`, which bounds one call.
harness_git() {
  local dir="$1" auth="${FORGE_PERF_HARNESS_AUTH:-${SQ_AUTH:-app}}" ssm="${FORGE_PERF_SSM_PATH:-/forge-perf}"
  case "$auth" in
    deploy-key)
      HARNESS_URL="${FORGE_PERF_HARNESS_URL:-git@github.com:$SQ_REPO.git}"
      (umask 077 && ssm_value "${FORGE_PERF_HARNESS_CREDENTIAL_PARAM:-$ssm/harness-deploy-key}" \
        >"$dir/harness-key") || return 1
      HARNESS_GIT=(env "GIT_SSH_COMMAND=ssh -i $dir/harness-key -o IdentitiesOnly=yes \
-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$FORGE_PERF_CHECKOUT/config/github-known-hosts" git)
      ;;
    app)
      HARNESS_URL="${FORGE_PERF_HARNESS_URL:-https://x-access-token@github.com/$SQ_REPO.git}"
      limited "$FORGE_PERF_CHECKOUT/scripts/host/harness-token.sh" \
        "${FORGE_PERF_HARNESS_APP_PARAM:-$ssm/harness-app}" "$dir" "$SQ_REPO" || return 1
      local helper="!f() { [ \"\$1\" = get ] && printf 'username=x-access-token\npassword=%s\n' \"\$(cat '$dir/harness-token')\"; }; f"
      HARNESS_GIT=(git -c credential.helper= -c "credential.helper=$helper")
      ;;
    none)
      HARNESS_URL="${FORGE_PERF_HARNESS_URL:-https://github.com/$SQ_REPO.git}"
      HARNESS_GIT=(git)
      ;;
    *) return 2 ;;
  esac
}

# run_active: a run holds the run lock, or forge-perf-run.service is starting,
# running or stopping. The unit is Type=oneshot, so `systemctl is-active`
# reports it inactive while it starts, and its ExecStopPost wipe runs after
# run.sh has let the lock go.
run_active() {
  if command -v flock >/dev/null; then
    mkdir -p "$FORGE_PERF_RUNTIME"
    flock -n "$FORGE_PERF_RUNTIME/run.lock" true || return 0
  elif host_ops_skipped; then
    # A laptop without flock: a run in progress has current.json.
    [ ! -e "$FORGE_PERF_STATE_DIR/current.json" ] || return 0
  fi
  case "$(host_read systemctl show -p ActiveState --value forge-perf-run.service)" in
    active | activating | deactivating | reloading) return 0 ;;
  esac
  return 1
}
