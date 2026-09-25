#!/usr/bin/env bash
# Adds a fixed round trip between smelt's node and central groups and checks it.
#
#   netem.sh apply              shape every node container (docs/DESIGN.md §5)
#   netem.sh verify pre|post    measure round trips and check the qdiscs; post
#                               also checks that nothing restarted or moved
#   netem.sh clear              remove the qdiscs
#   netem.sh throughput         iperf3 from ingot to piri-0 without and with
#                               the qdiscs; leaves them applied
#
# Groups come from config/groups.conf, the round trip and subnet from
# config/latency.env, the sidecar image from config/images.lock. Each command
# runs a netshoot sidecar in the target container's network namespace, so the
# host needs only docker; this works on the box and against Docker Desktop.
# forge-network must exist with NET_SUBNET before the stack starts:
#
#   docker network create --subnet 172.30.0.0/24 forge-network
#
# State and results go to $NETEM_DIR, default $RUN/netem, else ./netem:
# containers.tsv and central-ips (recorded at apply), latency.json (both
# verify passes), throughput.json, and the sidecar and docker events output.
#
# The environment can name another project (COMPOSE_PROJECT_NAME, default
# smelt) or network (NET_NAME), and can override RTT_MS, RTT_TOLERANCE_PCT and
# NET_SUBNET for a local try. A Docker Desktop VM adds a few ms of timer slack
# to every delayed packet, so a local verify may need a wider tolerance.
#
# Exit status: 0 passed, 1 a check failed (the run is invalid), 2 the stack,
# the configuration or the sidecar is not usable (a harness error).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
config="${FORGE_PERF_CONFIG:-$here/../../config}"
project="${COMPOSE_PROJECT_NAME:-smelt}"
network="${NET_NAME:-forge-network}"
state="${NETEM_DIR:-${RUN:+$RUN/netem}}"
state="${state:-$PWD/netem}"

# A value set in the environment wins over the file; the box sets none.
env_rtt="${RTT_MS:-}" env_tol="${RTT_TOLERANCE_PCT:-}" env_subnet="${NET_SUBNET:-}"
# shellcheck source=../../config/latency.env
. "$config/latency.env"
RTT_MS="${env_rtt:-$RTT_MS}"
RTT_TOLERANCE_PCT="${env_tol:-$RTT_TOLERANCE_PCT}"
NET_SUBNET="${env_subnet:-$NET_SUBNET}"
# shellcheck source=../../config/groups.conf
. "$config/groups.conf"
netshoot="$(awk '$1 ~ /^nicolaka\/netshoot:/ { print $1; exit }' "$config/images.lock")"

INTRA_MAX_MS=1
THROUGHPUT_BYTES=1G
THROUGHPUT_TOLERANCE_PCT=5
# Round trips checked on every pass, from:to:kind, each judged by the median
# of 20 pings. `host` is the drill client's view, from the host's namespace.
PAIRS="ingot:upload:cross ingot:hilt:cross ingot:plc:cross ingot:swarf:cross
ingot:delegator:cross ingot:signing-service:cross piri-0:upload:cross
piri-0:signing-service:cross upload:piri-0:cross ingot:piri-0:intra
ingot:ingot-postgres:intra upload:hilt:intra host:ingot:intra"
# TCP connects, from:to:port:path, 10 each; the median must be in the band.
CONNECTS="ingot:upload:80:/health upload:piri-0:3000:/readyz"

harness() { echo "netem: $*" >&2; exit 2; }
in_list() { case " $(echo "$2" | tr '\n' ' ') " in *" $1 "*) return 0 ;; esac; return 1; }
between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; }

ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(((a << 24) + (b << 16) + (c << 8) + d))
}
in_subnet() {
  local bits="${2#*/}" mask
  mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
  [ $(($(ip2int "$1") & mask)) -eq $(($(ip2int "${2%/*}") & mask)) ]
}

# sidecar <network> <mode> [args...]: netem-apply.sh in a netshoot container.
sidecar() {
  local opts=(--network "$1" --cap-add NET_ADMIN)
  shift
  [ "${opts[1]}" != host ] || opts=(--network host)
  docker run --rm -i "${opts[@]}" "$netshoot" bash -s -- "$@" <"$here/netem-apply.sh"
}

# facts <cid>: status, exit code, start time, restart count, forge-network IP.
facts() {
  docker inspect -f "{{.State.Status}} {{.State.ExitCode}} {{.State.StartedAt}} {{.RestartCount}} {{with index .NetworkSettings.Networks \"$network\"}}{{or .IPAddress \"-\"}}{{else}}-{{end}}" "$1"
}

# discover: one container per service of the compose project, every service
# in exactly one group.
discover() {
  mkdir -p "$state"
  [ -n "$netshoot" ] || harness "no nicolaka/netshoot line in $config/images.lock"
  docker ps -a --no-trunc --filter "label=com.docker.compose.project=$project" \
    --format '{{.Label "com.docker.compose.service"}} {{.ID}}' | sort >"$state/discovered" ||
    harness "docker ps failed"
  [ -s "$state/discovered" ] || harness "no containers in compose project $project"
  local dup svc
  dup="$(awk '{ print $1 }' "$state/discovered" | uniq -d | tr '\n' ' ')"
  [ -z "$dup" ] || harness "more than one container for: $dup"
  # shellcheck disable=SC2086 # the lists are space-separated names
  dup="$(printf '%s\n' $NODE $CENTRAL $OTHER $ONESHOT | sort | uniq -d | tr '\n' ' ')"
  [ -z "$dup" ] || harness "groups.conf lists these in more than one group: $dup"
  while read -r svc _; do
    in_list "$svc" "$NODE $CENTRAL $OTHER $ONESHOT" ||
      harness "service $svc is in no group of config/groups.conf; add it before running"
  done <"$state/discovered"
}
cid_of() { awk -v s="$1" '$1 == s { print $2 }' "$state/discovered"; }
# row <svc> <column>: from containers.tsv (svc group cid started restarts ip).
row() { awk -v s="$1" -v c="$2" '$1 == s { print $c }' "$state/containers.tsv"; }

cmd_apply() {
  discover
  rm -f "$state/containers.tsv" "$state/central-ips"
  local svc cid f group status code started restarts ip central=""
  for svc in $ONESHOT; do
    cid="$(cid_of "$svc")"
    [ -n "$cid" ] || continue
    f="$(facts "$cid")" || harness "cannot inspect $svc"
    read -r status code _ <<<"$f"
    [ "$status" = exited ] && [ "$code" = 0 ] ||
      harness "one-shot $svc is $status with exit code $code; it must have exited 0"
  done
  date +%s >"$state/applied-at"
  : >"$state/containers.tmp"
  for svc in $NODE $CENTRAL; do
    cid="$(cid_of "$svc")"
    [ -n "$cid" ] || continue
    group=node
    in_list "$svc" "$CENTRAL" && group=central
    f="$(facts "$cid")" || harness "cannot inspect $svc"
    read -r status code started restarts ip <<<"$f"
    [ "$status" = running ] || harness "$svc is $status"
    if [ "$ip" = - ]; then
      [ "$group" = node ] || harness "central $svc has no $network address"
      echo "netem: $svc has no $network address; not shaped"
    else
      in_subnet "$ip" "$NET_SUBNET" || harness "$svc address $ip is outside NET_SUBNET $NET_SUBNET"
    fi
    [ "$group" = node ] || central="$central $ip"
    echo "$svc $group $cid $started $restarts $ip" >>"$state/containers.tmp"
  done
  [ -n "$central" ] || harness "no central containers are running"
  # shellcheck disable=SC2086
  printf '%s\n' $central | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n >"$state/central-ips"
  mv "$state/containers.tmp" "$state/containers.tsv"
  local ips shaped=0
  ips="$(tr '\n' ' ' <"$state/central-ips")"
  while read -r svc group cid _ _ ip; do
    [ "$group" = node ] && [ "$ip" != - ] || continue
    # shellcheck disable=SC2086 # one argument per central address
    sidecar "container:$cid" apply "$ip" "$RTT_MS" $ips >"$state/apply-$svc.out" 2>&1 ||
      harness "sidecar could not shape $svc: $(tail -n 1 "$state/apply-$svc.out")"
    shaped=$((shaped + 1))
  done <"$state/containers.tsv"
  echo "netem: $shaped node containers delay ${RTT_MS} ms to $(wc -l <"$state/central-ips" | tr -d ' ') central addresses"
}

cmd_clear() {
  discover
  local svc cid f status ip
  for svc in $NODE; do
    cid="$(cid_of "$svc")"
    [ -n "$cid" ] || continue
    f="$(facts "$cid")" || harness "cannot inspect $svc"
    read -r status _ _ _ ip <<<"$f"
    [ "$status" = running ] && [ "$ip" != - ] || continue
    sidecar "container:$cid" clear "$ip" >/dev/null || harness "sidecar could not clear $svc"
  done
  echo "netem: cleared"
}

cmd_verify() {
  local pass="${1:-}"
  case "$pass" in pre | post) ;; *) usage ;; esac
  [ -s "$state/containers.tsv" ] || harness "no apply state in $state; run apply first"
  local lo hi reasons="$state/reasons-$pass" pings="$state/pings-$pass" connects="$state/connects-$pass"
  lo="$(awk -v r="$RTT_MS" -v t="$RTT_TOLERANCE_PCT" 'BEGIN { print r * (1 - t / 100) }')"
  hi="$(awk -v r="$RTT_MS" -v t="$RTT_TOLERANCE_PCT" 'BEGIN { print r * (1 + t / 100) }')"
  : >"$reasons"
  : >"$pings"
  : >"$connects"
  fail() { echo "$*" >>"$reasons"; }
  address() {
    local ip
    ip="$(row "$1" 6)"
    [ -n "$ip" ] && [ "$ip" != - ] || harness "no $network address recorded for $1"
    echo "$ip"
  }
  netns() {
    [ "$1" != host ] || { echo host; return; }
    local cid
    cid="$(row "$1" 3)"
    [ -n "$cid" ] || harness "$1 was not recorded at apply"
    echo "container:$cid"
  }

  # Round trips: one sidecar per source, its pings in parallel.
  local p src net from to kind ip targets out n mean med max
  for src in $(for p in $PAIRS; do echo "${p%%:*}"; done | awk '!seen[$0]++'); do
    net="$(netns "$src")"
    targets=""
    for p in $PAIRS; do
      [ "${p%%:*}" = "$src" ] || continue
      to="${p#*:}"
      targets="$targets $(address "${to%%:*}")"
    done
    # shellcheck disable=SC2086
    out="$(sidecar "$net" ping $targets)" || harness "ping sidecar failed in $src"
    echo "$out" >>"$state/sidecar-$pass.out"
    for p in $PAIRS; do
      IFS=: read -r from to kind <<<"$p"
      [ "$from" = "$src" ] || continue
      ip="$(address "$to")"
      read -r n mean med max <<<"$(echo "$out" | awk -v ip="$ip" '$1 == "ping" && $2 == ip { print $3, $4, $5, $6 }')"
      echo "$from $to $kind ${n:-0} ${mean:--} ${med:--} ${max:--}" >>"$pings"
      if [ "${n:-0}" = 0 ]; then
        fail "no reply from $to to $from"
      elif [ "$kind" = cross ]; then
        between "$med" "$lo" "$hi" || fail "$from -> $to median round trip $med ms is outside $lo-$hi ms"
      else
        between "$med" 0 "$INTRA_MAX_MS" || fail "$from -> $to median round trip $med ms is not under $INTRA_MAX_MS ms"
      fi
    done
  done

  local c port path ok tcp first
  for c in $CONNECTS; do
    IFS=: read -r from to port path <<<"$c"
    net="$(netns "$from")"
    ip="$(address "$to")"
    out="$(sidecar "$net" connect "http://$ip:$port$path" 10)" ||
      harness "connect sidecar failed in $from"
    read -r _ ok tcp first <<<"$out"
    echo "$from $to ${ok:-0} ${tcp:--} ${first:--}" >>"$connects"
    if [ "${ok:-0}" = 0 ]; then
      fail "no TCP connection from $from to $to:$port"
    else
      between "$tcp" "$lo" "$hi" || fail "$from -> $to median connect $tcp ms is outside $lo-$hi ms"
    fi
  done

  # The qdiscs: present, the configured delay, filters equal to the central set.
  local svc group cid started restarts want
  want="$(tr '\n' ' ' <"$state/central-ips")"
  while read -r svc group cid _ _ ip; do
    [ "$group" = node ] && [ "$ip" != - ] || continue
    out="$(sidecar "container:$cid" show "$ip" 2>&1)" || { fail "$svc: cannot read its qdiscs"; continue; }
    [ "$(echo "$out" | awk '$1 == "root" { print $2 }')" = prio ] || fail "$svc: no prio root qdisc"
    echo "$out" | awk -v r="$RTT_MS" '$1 == "delay" { v = $2 + 0; if ($2 ~ /us$/) v /= 1000; else if ($2 ~ /[0-9]s$/) v *= 1000; ok = (v == r) } END { exit !ok }' ||
      fail "$svc: netem delay is not ${RTT_MS} ms"
    [ "$(echo "$out" | awk '$1 == "filter" { print $2 }' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tr '\n' ' ')" = "$want" ] ||
      fail "$svc: filters do not match the central addresses recorded at apply"
  done <"$state/containers.tsv"

  if [ "$pass" = post ]; then
    local now now_status now_started now_restarts now_ip
    while read -r svc group cid started restarts ip; do
      if ! now="$(facts "$cid" 2>/dev/null)"; then
        fail "$svc: container $cid is gone"
        continue
      fi
      read -r now_status _ now_started now_restarts now_ip <<<"$now"
      [ "$now_status" = running ] || fail "$svc is $now_status"
      [ "$now_started" = "$started" ] && [ "$now_restarts" = "$restarts" ] ||
        fail "$svc restarted after apply (a node loses its qdisc; a central container can return on another address)"
      [ "$group" != central ] || [ "$now_ip" = "$ip" ] ||
        fail "$svc address changed from $ip to $now_ip; the filters no longer match it"
    done <"$state/containers.tsv"
    docker events --since "$(cat "$state/applied-at")" --until "$(date +%s)" \
      --filter type=container --filter "label=com.docker.compose.project=$project" \
      --filter event=die --filter event=start --filter event=restart \
      --format '{{.Actor.ID}} {{.Action}} {{json .}}' >"$state/events-post" || harness "docker events failed"
    while read -r cid kind _; do
      svc="$(awk -v c="$cid" '$3 == c { print $1 }' "$state/containers.tsv")"
      [ -z "$svc" ] || fail "$svc: $kind event after apply"
    done <"$state/events-post"
  fi

  awk '!seen[$0]++' "$reasons" >"$reasons.tmp" && mv "$reasons.tmp" "$reasons"
  write_json "$pass"
  if [ -s "$reasons" ]; then
    echo "netem: verify $pass failed:" >&2
    sed 's/^/  /' "$reasons" >&2
    exit 1
  fi
  echo "netem: verify $pass passed; details in $state/latency.json"
}

# write_json <pass>: latency-<pass>.json from the pass's files, then
# latency.json holding both passes.
write_json() {
  awk -v pass="$1" -v rtt="$RTT_MS" -v tol="$RTT_TOLERANCE_PCT" -v node=" $NODE " -v central=" $CENTRAL " '
    function num(v) { return v == "-" ? "null" : v + 0 }
    function median(a, n,   i, j, t) {
      if (!n) return "null"
      for (i = 2; i <= n; i++) for (j = i; j > 1 && a[j - 1] + 0 > a[j] + 0; j--) { t = a[j]; a[j] = a[j - 1]; a[j - 1] = t }
      return (n % 2 ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2) + 0
    }
    FILENAME == ARGV[1] {
      pairs = pairs sep sprintf("{\"from\":\"%s\",\"to\":\"%s\",\"kind\":\"%s\",\"received\":%d,\"mean_ms\":%s,\"median_ms\":%s,\"max_ms\":%s}", $1, $2, $3, $4, num($5), num($6), num($7))
      sep = ","
      if ($6 == "-") next
      if ($3 == "cross" && index(node, " " $1 " ")) out[++no] = $6
      if ($3 == "cross" && index(central, " " $1 " ")) back[++nb] = $6
      if ($3 == "intra" && $1 != "host" && (intra == "" || $7 + 0 > intra)) intra = $7 + 0
      if ($1 == "host") host = $6 + 0
      next
    }
    FILENAME == ARGV[2] {
      conns = conns csep sprintf("{\"from\":\"%s\",\"to\":\"%s\",\"ok\":%d,\"connect_median_ms\":%s,\"starttransfer_median_ms\":%s}", $1, $2, $3, num($4), num($5))
      csep = ","
      next
    }
    { reasons = reasons rsep "\"" $0 "\""; rsep = "," }
    END {
      printf "{\"pass\":\"%s\",\"rtt_ms\":%s,\"tolerance_pct\":%s,", pass, rtt, tol
      printf "\"node_to_central_median_ms\":%s,\"central_to_node_median_ms\":%s,", median(out, no), median(back, nb)
      printf "\"intra_group_max_ms\":%s,\"host_to_ingot_ms\":%s,", (intra == "" ? "null" : intra), (host == "" ? "null" : host)
      printf "\"pairs\":[%s],\"connects\":[%s],\"ok\":%s,\"reasons\":[%s]}\n", pairs, conns, (reasons == "" ? "true" : "false"), reasons
    }' "$state/pings-$1" "$state/connects-$1" "$state/reasons-$1" >"$state/latency-$1.json"
  local pre=null post=null
  [ ! -s "$state/latency-pre.json" ] || pre="$(cat "$state/latency-pre.json")"
  [ ! -s "$state/latency-post.json" ] || post="$(cat "$state/latency-post.json")"
  printf '{"pre":%s,"post":%s}\n' "$pre" "$post" >"$state/latency.json"
}

cmd_throughput() {
  discover
  local ingot piri piri_ip f status without with diff
  ingot="$(cid_of ingot)"
  piri="$(cid_of piri-0)"
  [ -n "$ingot" ] && [ -n "$piri" ] || harness "throughput needs ingot and piri-0"
  f="$(facts "$piri")" || harness "cannot inspect piri-0"
  read -r status _ _ _ piri_ip <<<"$f"
  [ "$status" = running ] && [ "$piri_ip" != - ] || harness "piri-0 is $status with address $piri_ip"
  measure() {
    local name="forge-perf-iperf-$$" out
    docker run -d --rm --name "$name" --network "container:$piri" "$netshoot" iperf3 -s -1 >/dev/null ||
      harness "cannot start the iperf3 server in piri-0"
    out="$(sidecar "container:$ingot" iperf "$piri_ip" "$THROUGHPUT_BYTES")" || {
      docker rm -f "$name" >/dev/null 2>&1 || true
      harness "iperf3 from ingot to piri-0 failed"
    }
    docker rm -f "$name" >/dev/null 2>&1 || true
    echo "$out" | awk '$1 == "iperf" { print $2 }'
  }
  cmd_clear >/dev/null
  without="$(measure)"
  cmd_apply
  with="$(measure)"
  [ -n "$without" ] && [ -n "$with" ] || harness "iperf3 reported no rate"
  diff="$(awk -v a="$without" -v b="$with" 'BEGIN { d = (b - a) / a * 100; printf "%.2f", (d < 0 ? -d : d) }')"
  printf '{"bytes":"%s","without_mbps":%s,"with_mbps":%s,"difference_pct":%s}\n' \
    "$THROUGHPUT_BYTES" "$without" "$with" "$diff" >"$state/throughput.json"
  echo "netem: ingot -> piri-0 without the qdisc $without Mbit/s, with it $with Mbit/s, $diff% apart"
  between "$diff" 0 "$THROUGHPUT_TOLERANCE_PCT" || {
    echo "netem: throughput differs by more than $THROUGHPUT_TOLERANCE_PCT%" >&2
    exit 1
  }
}

usage() {
  echo "usage: netem.sh apply | verify pre|post | clear | throughput" >&2
  exit 2
}

case "${1:-}" in
  apply) cmd_apply ;;
  verify) cmd_verify "${2:-}" ;;
  clear) cmd_clear ;;
  throughput) cmd_throughput ;;
  *) usage ;;
esac
