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
# run.sh has let the lock go. An experiment counts as a run from its start to
# its end, its runs and the gaps between them alike, so no live run and no
# update starts inside a pair.
run_active() {
  local unit
  if command -v flock >/dev/null; then
    mkdir -p "$FORGE_PERF_RUNTIME"
    flock -n "$FORGE_PERF_RUNTIME/run.lock" true || return 0
    flock -n "$FORGE_PERF_RUNTIME/experiment.lock" true || return 0
  elif host_ops_skipped; then
    # A laptop without flock: a run in progress has current.json.
    [ ! -e "$FORGE_PERF_STATE_DIR/current.json" ] || return 0
  fi
  for unit in forge-perf-run.service forge-perf-experiment.service; do
    case "$(host_read systemctl show -p ActiveState --value "$unit")" in
      active | activating | deactivating | reloading) return 0 ;;
    esac
  done
  return 1
}

# The requests bucket (docs/runner.md, "Experiments"): requests/<id>.json from
# a service repository's /forge-perf workflow, status/<id>.json from the box.
# The caller defines `limited`, which bounds one call.
requests_bucket() { echo "${FORGE_PERF_REQUESTS_BUCKET:-forge-perf-requests-654654381893}"; }

# put_status ID < status JSON: status/<id>.json, whole each time.
put_status() {
  local tmp status=0
  tmp="$(mktemp "$FORGE_PERF_RUNTIME/status.XXXXXX")"
  cat >"$tmp"
  limited aws s3api put-object --bucket "$(requests_bucket)" --key "status/$1.json" --body "$tmp" \
    --content-type application/json >/dev/null || status=1
  rm -f "$tmp"
  [ "$status" -eq 0 ] || echo "the status of experiment $1 did not go up" >&2
  return "$status"
}

# delete_request ID: the request is finished, refused or failed.
delete_request() {
  limited aws s3api delete-object --bucket "$(requests_bucket)" --key "requests/$1.json" >/dev/null ||
    { echo "cannot delete request $1; the next poll pass tries again" >&2; return 1; }
}

# grafana_export RUNNER RECORD RUN_DIR: send the run's results from RECORD to
# Prometheus and, for a traced run, its scrubbed spans from
# RUN_DIR/traces/traces.jsonl to Tempo, through a one-shot collector,
# forge-perf-grafana, run from config/otel-grafana.yaml (docs/runner.md,
# "Grafana"). config/grafana.conf names both services; an empty endpoint or
# user turns that half off. The token, SSM <path>/grafana-token, goes into a
# mode-600 file under $FORGE_PERF_RUNTIME/secrets that the collector reads
# from a read-only mount and the step removes: never argv, an environment, a
# log or RUN_DIR. A local run sends only with FORGE_PERF_GRAFANA_TOKEN_FILE
# naming a file that holds the token. The collector's log goes to
# RUN_DIR/grafana-export.log once checked for the token. Best effort under
# GRAFANA_TIMEOUT_S, plus GRAFANA_TRACE_S_PER_GB for each GB of traces.jsonl
# up to GRAFANA_TIMEOUT_MAX_S: whatever happens it logs a line and returns 0,
# so the run's class, reasons and flags, its upload and its wipe never depend
# on it. Callers under set -e add `|| true`, which keeps a failing command
# inside from ending the caller.
grafana_export() {
  local runner="$1" record="$2" run_dir="$3" conf="$FORGE_PERF_CHECKOUT/config/grafana.conf"
  local traces="" tok status=0 started=$SECONDS end budget bytes cap ssm_s left tail image
  local tempo=off prom=off send_traces="" send_results="" ready="" counts="" started_collector=""
  local port="${FORGE_PERF_GRAFANA_PORT:-14318}" mport="${FORGE_PERF_GRAFANA_METRICS_PORT:-18888}"
  local -a opts=()
  step "grafana"
  local GRAFANA_TEMPO_ENDPOINT="" GRAFANA_TEMPO_USER="" GRAFANA_PROM_URL="" GRAFANA_PROM_USER=""
  local GRAFANA_TIMEOUT_S=120 GRAFANA_MAX_REQUEST_BYTES=4000000 GRAFANA_TRACE_S_PER_GB=150 GRAFANA_TIMEOUT_MAX_S=600
  # shellcheck source=../../config/grafana.conf
  . "$conf" 2>/dev/null || { echo "grafana: cannot read config/grafana.conf; nothing sent" >&2; return 0; }
  [[ "$GRAFANA_TIMEOUT_S" =~ ^[1-9][0-9]{0,3}$ ]] || GRAFANA_TIMEOUT_S=120
  [[ "$GRAFANA_TRACE_S_PER_GB" =~ ^[0-9]{1,4}$ ]] || GRAFANA_TRACE_S_PER_GB=150
  [[ "$GRAFANA_TIMEOUT_MAX_S" =~ ^[1-9][0-9]{0,3}$ ]] || GRAFANA_TIMEOUT_MAX_S=600
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [[ "$mport" =~ ^[1-9][0-9]{0,4}$ ]] ||
    { echo "grafana: FORGE_PERF_GRAFANA_PORT and FORGE_PERF_GRAFANA_METRICS_PORT must be ports; nothing sent" >&2; return 0; }
  [ -z "$run_dir" ] || traces="$run_dir/traces/traces.jsonl"
  # A traced run's spans take longer to scrub and send the more there are.
  budget="$GRAFANA_TIMEOUT_S"
  if [ -n "$traces" ] && [ -f "$traces" ] && bytes="$(wc -c <"$traces" | tr -d ' ')" &&
    [[ "$bytes" =~ ^[0-9]{1,15}$ ]]; then
    budget=$((GRAFANA_TIMEOUT_S + bytes * GRAFANA_TRACE_S_PER_GB / 1000000000))
    cap=$((GRAFANA_TIMEOUT_MAX_S > GRAFANA_TIMEOUT_S ? GRAFANA_TIMEOUT_MAX_S : GRAFANA_TIMEOUT_S))
    budget=$((budget < cap ? budget : cap))
  fi
  end=$((started + budget))
  # What the collector needs after the upload: the wait for its queues and
  # its stop.
  tail=$((budget >= 120 ? 30 : budget / 4))

  if [ -n "$GRAFANA_TEMPO_ENDPOINT" ] && [ -n "$GRAFANA_TEMPO_USER" ]; then
    if [[ "$GRAFANA_TEMPO_ENDPOINT" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] && [[ "$GRAFANA_TEMPO_USER" =~ ^[0-9]{1,12}$ ]]; then
      tempo=on
    else
      echo "grafana: GRAFANA_TEMPO_ENDPOINT must be host:port and GRAFANA_TEMPO_USER a number; traces off" >&2
    fi
  fi
  if [ -n "$GRAFANA_PROM_URL" ] && [ -n "$GRAFANA_PROM_USER" ]; then
    if [[ "$GRAFANA_PROM_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._/-]*)?$ ]] &&
      [[ "$GRAFANA_PROM_USER" =~ ^[0-9]{1,12}$ ]]; then
      prom=on
    else
      echo "grafana: GRAFANA_PROM_URL must be an https:// URL and GRAFANA_PROM_USER a number; results off" >&2
    fi
  fi
  if [ "$tempo" = off ] && [ "$prom" = off ]; then
    echo "grafana: no Tempo or Prometheus in config/grafana.conf; nothing sent" >&2
    return 0
  fi
  [ "$tempo" = off ] || [ -z "$traces" ] || [ ! -e "$traces" ] || send_traces=1
  [ "$prom" = off ] || [ ! -s "$record" ] || send_results=1
  if [ -z "$send_traces$send_results" ]; then
    echo "grafana: nothing to send" >&2
    return 0
  fi

  mkdir -p "$FORGE_PERF_RUNTIME/secrets" || { echo "grafana: cannot write the token file; nothing sent" >&2; return 0; }
  tok="$FORGE_PERF_RUNTIME/secrets/grafana-token"
  if [ -n "${FORGE_PERF_GRAFANA_TOKEN_FILE:-}" ]; then
    (umask 077 && tr -d '\r\n' <"$FORGE_PERF_GRAFANA_TOKEN_FILE" >"$tok") 2>/dev/null || rm -f "$tok"
  elif host_ops_skipped || [ "${FORGE_PERF_SECRETS:-ssm}" != ssm ]; then
    echo "grafana: a local run sends only with FORGE_PERF_GRAFANA_TOKEN_FILE set; nothing sent" >&2
    return 0
  else
    # The SSM read spends from the same budget, capped at 20 s (a sixth of a
    # short one). SSM's text output ends in a newline, which would become
    # part of the password.
    ssm_s=$((GRAFANA_TIMEOUT_S >= 120 ? 20 : GRAFANA_TIMEOUT_S / 6 + 2))
    (umask 077 && set -o pipefail && timeout --kill-after=2 "$ssm_s" aws ssm get-parameter --with-decryption \
      --name "${FORGE_PERF_GRAFANA_PARAM:-${FORGE_PERF_SSM_PATH:-/forge-perf}/grafana-token}" \
      --query Parameter.Value --output text 2>/dev/null | tr -d '\r\n' >"$tok") || rm -f "$tok"
  fi
  if [ ! -s "$tok" ]; then
    rm -f "$tok"
    echo "grafana: no token in SSM; nothing sent" >&2
    return 0
  fi

  # The image runs as 10001; root on the box hands it the file. A laptop's
  # user cannot chown, so the collector runs as that user instead.
  chown 10001:10001 "$tok" 2>/dev/null || opts=(--user "$(id -u):$(id -g)")
  # A half that is off gets placeholders its exporter needs to pass
  # validation, and nop in its pipeline, so that exporter never starts.
  if [ "$tempo" = on ]; then
    opts+=(-e "GRAFANA_TEMPO_ENDPOINT=$GRAFANA_TEMPO_ENDPOINT" -e "GRAFANA_TEMPO_USER=$GRAFANA_TEMPO_USER")
  else
    opts+=(-e GRAFANA_TEMPO_ENDPOINT=127.0.0.1:9 -e GRAFANA_TEMPO_USER=0)
  fi
  if [ "$prom" = on ]; then
    opts+=(-e "GRAFANA_PROM_URL=$GRAFANA_PROM_URL" -e "GRAFANA_PROM_USER=$GRAFANA_PROM_USER")
  else
    opts+=(-e GRAFANA_PROM_URL=https://127.0.0.1:9/ -e GRAFANA_PROM_USER=0)
  fi
  image="$(awk '$1 == "OTEL_COLLECTOR_IMAGE" { sub(/:[^:\/]*$/, "", $2); print $2 "@" $3; exit }' \
    "$FORGE_PERF_CHECKOUT/config/images.lock" 2>/dev/null)" || image=""
  set -- --config /etc/forge-perf/otel-grafana.yaml
  [ "$tempo" = on ] || set -- "$@" '--set=service::pipelines::traces::exporters=[nop]'
  [ "$prom" = on ] || set -- "$@" '--set=service::pipelines::metrics::exporters=[nop]'

  docker rm -f forge-perf-grafana >/dev/null 2>&1 || true
  if [ -z "$image" ]; then
    echo "grafana: no OTEL_COLLECTOR_IMAGE in config/images.lock; nothing sent" >&2
  elif ! docker image inspect "$image" >/dev/null 2>&1 &&
    ! timeout --kill-after=5 "$(((end - SECONDS - tail) > 2 ? end - SECONDS - tail : 2))" \
      docker pull --quiet "$image" >/dev/null 2>&1; then
    echo "grafana: cannot pull the collector image; nothing sent" >&2
  elif ! docker run -d --name forge-perf-grafana --cpus 2 --memory 2g "${opts[@]}" \
    -p "127.0.0.1:$port:4318" -p "127.0.0.1:$mport:8888" \
    -v "$tok:/secrets/token:ro" \
    -v "$FORGE_PERF_CHECKOUT/config/otel-grafana.yaml:/etc/forge-perf/otel-grafana.yaml:ro" \
    "$image" "$@" >/dev/null; then
    echo "grafana: cannot start the collector; nothing sent" >&2
  else
    started_collector=1
    # Ready once the receiver answers HTTP; Docker's proxy accepts the
    # connection before the collector listens.
    for _ in $(seq 20); do
      if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/"; then
        ready=1
        break
      fi
      [ $((end - SECONDS)) -gt "$tail" ] || break
      sleep 1
    done
    if [ -z "$ready" ]; then
      echo "grafana: the collector did not start; nothing sent" >&2
    else
      left=$((end - SECONDS - tail))
      [ "$left" -ge 2 ] || left=2
      set -- --endpoint "http://127.0.0.1:$port" --runner "$runner" \
        --span-attributes "$FORGE_PERF_CHECKOUT/config/grafana-span-attributes.txt" \
        --max-request-bytes "$GRAFANA_MAX_REQUEST_BYTES" \
        --deadline $((left > 20 ? left - 10 : left / 2))
      [ -z "$send_results" ] || set -- "$@" --record "$record"
      [ -z "$send_traces" ] || set -- "$@" --traces "$traces"
      timeout --kill-after=5 "$left" python3 "$FORGE_PERF_CHECKOUT/scripts/host/grafana-export.py" "$@" ||
        status=$?
      case "$status" in
        0) ;;
        124 | 137) echo "grafana: ran over ${budget}s; the run goes on" >&2 ;;
        *) echo "grafana: grafana-export.py exited $status; the run goes on" >&2 ;;
      esac
      # The exporters send from their queues and retry; wait until both are
      # empty or ten seconds of the budget are left.
      while :; do
        counts="$(grafana_counts "$mport")" && [ "${counts##* }" = 0 ] && break
        [ $((end - SECONDS)) -gt 10 ] || break
        sleep 2
      done
      grafana_summary "$counts"
    fi
  fi
  grafana_close "$tok" "$run_dir" $((end - SECONDS - 5)) "$started_collector"
  return 0
}

# grafana_counts PORT: the collector's counters, from its metrics on
# 127.0.0.1:PORT, as "accepted sent failed" for spans, the same for metric
# points, then the requests in the exporters' queues, including any being
# retried. Fails when the collector does not answer.
grafana_counts() {
  local text
  text="$(curl -sf --max-time 5 "http://127.0.0.1:$1/metrics")" || return 1
  awk '
    /^#/ { next }
    {
      name = $1; sub(/\{.*/, "", name); sub(/_total$/, "", name)
      if (name in n) n[name] += $NF
    }
    BEGIN {
      split("otelcol_receiver_accepted_spans otelcol_exporter_sent_spans otelcol_exporter_send_failed_spans " \
        "otelcol_receiver_accepted_metric_points otelcol_exporter_sent_metric_points " \
        "otelcol_exporter_send_failed_metric_points otelcol_exporter_queue_size", keys, " ")
      for (i = 1; i <= 7; i++) n[keys[i]] = 0
    }
    END { for (i = 1; i <= 7; i++) printf "%d%s", n[keys[i]], (i < 7 ? " " : "\n") }
  ' <<<"$text"
}

# grafana_summary COUNTS: the step's line. Unsent is what the collector
# accepted and had neither sent nor given up on when the step stopped waiting.
grafana_summary() {
  local as ss fs ap sp fp q
  if [ -z "$1" ]; then
    echo "grafana: cannot read the collector's counters; its errors follow" >&2
    return 0
  fi
  read -r as ss fs ap sp fp q <<<"$1"
  echo "grafana: spans $ss sent, $fs failed, $((as - ss - fs > 0 ? as - ss - fs : 0)) unsent;" \
    "points $sp sent, $fp failed, $((ap - sp - fp > 0 ? ap - sp - fp : 0)) unsent" >&2
}

# grafana_close TOKEN RUN_DIR GRACE [STARTED]: stop the collector with GRACE
# seconds (1 to 30) to flush, keep its log in RUN_DIR/grafana-export.log
# and print its last error lines once a check finds no token in it, and
# remove the collector and the token file.
grafana_close() {
  local tok="$1" run_dir="$2" grace="$3" log="$FORGE_PERF_RUNTIME/secrets/grafana-export.log"
  [ "$grace" -ge 1 ] || grace=1
  [ "$grace" -le 30 ] || grace=30
  if [ -z "${4:-}" ]; then
    docker rm -f forge-perf-grafana >/dev/null 2>&1 || true
  else
    timeout --kill-after=5 $((grace + 10)) docker stop -t "$grace" forge-perf-grafana >/dev/null 2>&1 ||
      echo "grafana: the collector did not stop cleanly" >&2
    if docker logs forge-perf-grafana >"$log" 2>&1 && [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
      # grep exits 1 only when it read both files and found no token.
      grep -qF -f "$tok" "$log"
      case $? in
        0) echo "grafana: the collector's log holds the token; it is not kept" >&2 ;;
        1)
          # The log goes with the run directory at the wipe; its last
          # errors go to the journal.
          grep -i 'error' "$log" | tail -n 5 | sed 's/^/grafana: collector: /' >&2 || true
          mv "$log" "$run_dir/grafana-export.log" || echo "grafana: cannot keep the collector's log" >&2
          ;;
        *) echo "grafana: cannot check the collector's log for the token; it is not kept" >&2 ;;
      esac
    fi
    rm -f "$log" || true
    docker rm -f forge-perf-grafana >/dev/null 2>&1 || echo "grafana: the wipe removes the collector" >&2
  fi
  rm -f "$tok" || echo "grafana: cannot remove the token file; the wipe does" >&2
}
