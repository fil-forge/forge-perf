#!/usr/bin/env bash
# Behavior of netem.sh against a stubbed docker. The stub serves a smelt-shaped
# compose project from fixture files and answers the sidecar's modes, so each
# test changes one fact (a round trip, a restart, an event) and checks the
# verdict and exit status.
set -euo pipefail

netem="$(cd "$(dirname "$0")/.." && pwd -P)/netem.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/netem-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export FIX="$work/fix"
mkdir -p "$work/bin"
# The fixtures model a 15 ms round trip. A config copy pins it, so a change
# to config/latency.env leaves these tests alone.
cp -R "$(cd "$(dirname "$0")/../../.." && pwd -P)/config" "$work/config"
printf 'RTT_MS=15\nRTT_TOLERANCE_PCT=10\nNET_SUBNET=172.30.0.0/24\n' >"$work/config/latency.env"
export FORGE_PERF_CONFIG="$work/config"

cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"
shift
case "$cmd" in
  ps) cat "$FIX/ps" ;;
  inspect) for a in "$@"; do cid="$a"; done; cat "$FIX/inspect/$cid" ;;
  events) cat "$FIX/events" 2>/dev/null || true ;;
  rm) ;;
  run)
    net="" detach=0 cap=none
    while [ "$1" != -- ]; do
      case "$1" in --network) net="$2"; shift ;; --cap-add) cap="$2"; shift ;; -d) detach=1 ;; esac
      shift
      [ "$detach" = 0 ] || { echo server; exit 0; }
    done
    shift
    mode="$1"
    shift
    key="${net//:/_}"
    # Like docker: joining a namespace needs a running container.
    if [ "${net#container:}" != "$net" ]; then
      read -r st _ <"$FIX/inspect/${net#container:}" 2>/dev/null || st=gone
      [ "$st" = running ] || { echo "docker: cannot join network of a non running container" >&2; exit 125; }
    fi
    echo "$net $mode $*" >>"$FIX/log"
    echo "$mode $cap" >>"$FIX/caps"
    [ "$mode" != ping ] || [ ! -f "$FIX/ping-status" ] || exit "$(cat "$FIX/ping-status")"
    rtt() { awk -v n="$net" -v i="$1" '$1 == n && $2 == i { v = $3 } END { print (v == "" ? "0.100" : v) }' "$FIX/rtt"; }
    case "$mode" in
      apply) shift 2; printf '%s\n' "$@" >"$FIX/applied-$key"; echo "dev eth0"; exit "$(cat "$FIX/sidecar-status" 2>/dev/null || echo 0)" ;;
      clear) rm -f "$FIX/applied-$key" ;;
      show)
        echo "dev eth0"
        [ -f "$FIX/applied-$key" ] || exit 0
        printf 'root prio\ndelay 15ms\n'
        sed 's/^/filter /' "$FIX/applied-$key"
        ;;
      ping) for t in "$@"; do v="$(rtt "$t")"; echo "ping $t 20 $v $v $v"; done ;;
      connect) ip="${1#http://}"; echo "connect 10 $(rtt "${ip%%:*}") 30.0" ;;
      iperf) echo "iperf $(head -n 1 "$FIX/iperf")"; sed -i.bak 1d "$FIX/iperf" ;;
    esac
    ;;
esac
STUB
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"

node="ingot ingot-postgres ingot-openbao piri-0 piri-postgres"
central="upload postgres hilt hilt-postgres hilt-vault swarf swarf-postgres plc plc-postgres delegator signing-service dynamodb-local minio"
other="blockchain email guppy indexer redis ipni piri-minio"
oneshot="ingot-openbao-init piri-postgres-init upload-init hilt-init ipni-init"

# fixture: every service up, one address each; node -> central and
# upload -> piri-0 at 15 ms, everything else at 0.1 ms.
fixture() {
  rm -rf "$FIX" "$work/state"
  mkdir -p "$FIX/inspect"
  : >"$FIX/ps"
  : >"$FIX/rtt"
  local n=2 svc
  for svc in $node $central $other $oneshot; do
    echo "$svc c-$svc" >>"$FIX/ps"
    if [[ " $oneshot " == *" $svc "* ]]; then
      echo "exited 0 2026-09-25T00:00:00Z 0 172.30.0.$n" >"$FIX/inspect/c-$svc"
    elif [ "$svc" = piri-postgres ]; then
      echo "running 0 2026-09-25T00:00:00Z 0 -" >"$FIX/inspect/c-$svc"
    else
      echo "running 0 2026-09-25T00:00:00Z 0 172.30.0.$n" >"$FIX/inspect/c-$svc"
    fi
    eval "ip_${svc//-/_}=172.30.0.$n"
    n=$((n + 1))
  done
  for svc in ingot piri-0; do
    for c in $central; do
      echo "container:c-$svc $(ip_of "$c") 15.0" >>"$FIX/rtt"
    done
  done
  echo "container:c-upload $(ip_of piri-0) 15.0" >>"$FIX/rtt"
}
ip_of() { eval "echo \$ip_${1//-/_}"; }
set_rtt() { echo "container:c-$1 $(ip_of "$2") $3" >>"$FIX/rtt"; }

failures=0
out="$work/out"
# expect <status> <description> <pattern or -> -- <netem args>
expect() {
  local want="$1" what="$2" pattern="$3" got=0
  shift 4
  NETEM_DIR="$work/state" RTT_MS="${RTT_MS:-}" RTT_TOLERANCE_PCT="${RTT_TOLERANCE_PCT:-}" bash "$netem" "$@" >"$out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $what: exit $got, want $want"
    sed 's/^/    /' "$out"
    failures=$((failures + 1))
  elif [ "$pattern" != - ] && ! grep -q -e "$pattern" "$out"; then
    echo "FAIL: $what: output lacks '$pattern'"
    sed 's/^/    /' "$out"
    failures=$((failures + 1))
  else
    echo "ok: $what"
  fi
}

fixture
expect 0 "apply shapes the thirteen central containers" "13 central containers delay 15 ms to 4 node addresses" -- apply
[ "$(grep -c ' apply ' "$FIX/log")" -eq 13 ] || { echo "FAIL: apply ran $(grep -c ' apply ' "$FIX/log") sidecars, want 13"; failures=$((failures + 1)); }
for svc in $node; do
  grep -q "^container:c-$svc apply " "$FIX/log" && { echo "FAIL: node $svc was shaped"; failures=$((failures + 1)); }
done
[ "$(tr '\n' ' ' <"$work/state/node-ips")" = "$(ip_of ingot) $(ip_of ingot-postgres) $(ip_of ingot-openbao) $(ip_of piri-0) " ] ||
  { echo "FAIL: node-ips is not the sorted node addresses"; cat "$work/state/node-ips"; failures=$((failures + 1)); }
[ "$(tr '\n' ' ' <"$FIX/applied-container_c-hilt")" = "$(tr '\n' ' ' <"$work/state/node-ips")" ] ||
  { echo "FAIL: hilt filters are not the node addresses"; failures=$((failures + 1)); }
expect 0 "verify pre passes at 15 ms" "verify pre passed" -- verify pre
grep -q '"node_to_central_median_ms":15,"central_to_node_median_ms":15,"intra_group_max_ms":0.1,"host_to_ingot_ms":0.1' "$work/state/latency.json" ||
  { echo "FAIL: latency.json summary"; cat "$work/state/latency.json"; failures=$((failures + 1)); }
expect 0 "verify post passes with nothing changed" "verify post passed" -- verify post
grep -q '"net_subnet":"172.30.0.0/24","overridden":false' "$work/state/latency.json" ||
  { echo "FAIL: latency.json lacks the subnet record"; failures=$((failures + 1)); }
if [ -n "$(awk '$1 != "apply" && $1 != "clear" && $2 != "none"' "$FIX/caps")" ] || ! grep -q '^apply NET_ADMIN$' "$FIX/caps"; then
  echo "FAIL: only apply and clear get NET_ADMIN"
  cat "$FIX/caps"
  failures=$((failures + 1))
fi

set_rtt ingot hilt 17.0
expect 1 "a round trip above the band fails" "ingot -> hilt median round trip 17.0 ms is outside 13.5-16.5" -- verify pre
set_rtt ingot hilt 15.0
set_rtt ingot piri-0 1.5
expect 1 "an intra-node round trip over 1 ms fails" "ingot -> piri-0 median round trip 1.5 ms is not under 1" -- verify pre
set_rtt ingot piri-0 0.1

echo "running 0 2026-09-25T01:00:00Z 0 $(ip_of upload)" >"$FIX/inspect/c-upload"
expect 1 "a restarted central container fails post" "upload restarted after apply" -- verify post
echo "running 0 2026-09-25T01:00:00Z 1 172.30.0.200" >"$FIX/inspect/c-upload"
expect 1 "a central container on a new address fails post" "upload address changed from $(ip_of upload) to 172.30.0.200" -- verify post
echo "running 0 2026-09-25T00:00:00Z 0 $(ip_of upload)" >"$FIX/inspect/c-upload"
echo "running 0 2026-09-25T00:00:00Z 0 172.30.0.201" >"$FIX/inspect/c-piri-0"
expect 1 "a node container on a new address fails post" "piri-0 address changed from $(ip_of piri-0) to 172.30.0.201" -- verify post
echo "running 0 2026-09-25T00:00:00Z 0 $(ip_of piri-0)" >"$FIX/inspect/c-piri-0"
echo "c-piri-0 die {}" >"$FIX/events"
expect 1 "a die event after apply fails post" "piri-0: die event after apply" -- verify post
rm "$FIX/events"
sed -i.bak '$d' "$FIX/applied-container_c-hilt"
expect 1 "a missing filter fails verify" "hilt: filters do not match the node addresses recorded at apply" -- verify pre
rm "$FIX/applied-container_c-upload"
expect 1 "a missing qdisc fails verify" "upload: no prio root qdisc" -- verify pre

# A crashed node container is a failed check with the post record kept.
fixture
expect 0 "apply before a crash" - -- apply
expect 0 "verify pre before a crash" - -- verify pre
# docker inspect gives a stopped container no address.
echo "exited 137 2026-09-25T00:00:00Z 0 -" >"$FIX/inspect/c-piri-0"
echo "c-piri-0 die {}" >"$FIX/events"
expect 1 "an exited node container fails post" "piri-0 is exited" -- verify post
grep -q "piri-0 is not running; its round trips were not measured" "$out" ||
  { echo "FAIL: skipped probes not reported"; failures=$((failures + 1)); }
grep -q "address changed" "$out" && { echo "FAIL: a stopped container reported as a moved address"; failures=$((failures + 1)); }
grep -q '"post":{"pass":"post"' "$work/state/latency.json" && [ -s "$work/state/events-post" ] ||
  { echo "FAIL: post record lost after a crash"; cat "$work/state/latency.json"; failures=$((failures + 1)); }
! command -v python3 >/dev/null || python3 -m json.tool "$work/state/latency.json" >/dev/null ||
  { echo "FAIL: latency.json is not valid JSON"; failures=$((failures + 1)); }
rm "$FIX/events" "$FIX/inspect/c-ingot"
echo "running 0 2026-09-25T00:00:00Z 0 $(ip_of piri-0)" >"$FIX/inspect/c-piri-0"
expect 1 "a recreated node container fails post" "ingot: container c-ingot is gone" -- verify post
grep -q '"post":{"pass":"post"' "$work/state/latency.json" ||
  { echo "FAIL: post record lost after a recreate"; failures=$((failures + 1)); }
fixture
expect 0 "apply before a sidecar failure" - -- apply
echo 1 >"$FIX/ping-status"
expect 2 "a ping sidecar failing in a running container is a harness error" "ping sidecar failed in ingot" -- verify post
grep -q '"reasons":\["harness error: ping sidecar failed in ingot"\]' "$work/state/latency.json" ||
  { echo "FAIL: harness error not recorded"; cat "$work/state/latency.json"; failures=$((failures + 1)); }
! command -v python3 >/dev/null || python3 -m json.tool "$work/state/latency.json" >/dev/null ||
  { echo "FAIL: latency.json is not valid JSON after a harness error"; failures=$((failures + 1)); }

fixture
echo "newsvc c-newsvc" >>"$FIX/ps"
expect 2 "a service in no group stops apply" "service newsvc is in no group" -- apply
fixture
echo "exited 1 2026-09-25T00:00:00Z 0 -" >"$FIX/inspect/c-hilt-init"
expect 2 "a failed one-shot stops apply" "one-shot hilt-init is exited with exit code 1" -- apply
fixture
NET_SUBNET=10.0.0.0/24 expect 0 "NET_SUBNET in the environment is ignored" - -- apply
fixture
NETEM_LOCAL=1 NET_SUBNET=10.0.0.0/24 expect 2 "an address outside NET_SUBNET stops apply" "outside NET_SUBNET" -- apply
fixture
expect 0 "apply before a local override" - -- apply
NETEM_LOCAL=1 RTT_TOLERANCE_PCT=40 expect 0 "a local override is recorded" - -- verify pre
grep -q '"tolerance_pct":40,"net_subnet":"172.30.0.0/24","overridden":true' "$work/state/latency.json" ||
  { echo "FAIL: override not recorded"; cat "$work/state/latency.json"; failures=$((failures + 1)); }
fixture
echo 1 >"$FIX/sidecar-status"
expect 2 "a sidecar failure is a harness error" "sidecar could not shape" -- apply
fixture
echo "running 0 2026-09-25T00:00:00Z 0 172.30.0.100" >"$FIX/inspect/c-ingot"
expect 0 "apply with an address above .99" - -- apply
[ "$(tr '\n' ' ' <"$work/state/node-ips")" = "$(ip_of ingot-postgres) $(ip_of ingot-openbao) $(ip_of piri-0) 172.30.0.100 " ] ||
  { echo "FAIL: node-ips is not sorted numerically"; cat "$work/state/node-ips"; failures=$((failures + 1)); }
fixture
for svc in $node; do echo "running 0 2026-09-25T00:00:00Z 0 -" >"$FIX/inspect/c-$svc"; done
expect 2 "no node address stops apply" "no node container has a forge-network address" -- apply
[ ! -e "$work/state/containers.tsv" ] || { echo "FAIL: apply recorded state after stopping"; failures=$((failures + 1)); }
fixture
grep -v -E "^($(echo "$central" | tr ' ' '|')) " "$FIX/ps" >"$FIX/ps.new" && mv "$FIX/ps.new" "$FIX/ps"
expect 2 "no central container stops apply" "no central containers are running" -- apply
[ ! -e "$work/state/containers.tsv" ] || { echo "FAIL: apply recorded state after stopping"; failures=$((failures + 1)); }
fixture
expect 2 "verify without apply is a harness error" "run apply first" -- verify pre

fixture
printf '1000\n990\n' >"$FIX/iperf"
expect 0 "throughput within 5% passes" "upload -> minio without the qdiscs 1000 Mbit/s, with them 990 Mbit/s, 1.00% apart" -- throughput
grep -q '"without_mbps":1000,"with_mbps":990' "$work/state/throughput.json" || { echo "FAIL: throughput.json"; failures=$((failures + 1)); }
[ "$(grep -c "^container:c-upload iperf $(ip_of minio) " "$FIX/log")" -eq 2 ] ||
  { echo "FAIL: throughput did not run iperf3 from upload to minio twice"; grep iperf "$FIX/log"; failures=$((failures + 1)); }
[ -f "$FIX/applied-container_c-upload" ] || { echo "FAIL: throughput left the qdiscs cleared"; failures=$((failures + 1)); }
printf '1000\n900\n' >"$FIX/iperf"
expect 1 "throughput 10% apart fails" "differs by more than 5%" -- throughput

if [ "$failures" -ne 0 ]; then
  echo "netem: $failures failure(s)"
  exit 1
fi
echo "netem: all tests passed"
