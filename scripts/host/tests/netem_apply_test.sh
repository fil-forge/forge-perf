#!/usr/bin/env bash
# Behavior of netem-apply.sh, the sidecar half, with ip, tc and ping stubbed on
# PATH. The stubbed namespace has two networks, eth0 on another network and
# eth1 on forge-network, so the interface has to be chosen by address.
#
# Each check is a condition string that check() evals after the run, so its
# expansions stay single-quoted until then.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd -P)/netem-apply.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/netem-apply-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export LOG="$work/tc.log"
mkdir -p "$work/bin"

# Like the real ip, each stub writes more after the line netem-apply.sh wants
# (route get's "cache" line, an interface after the matching one). The pause
# lets a reader that stops at the first match close the pipe first, so under
# pipefail the late write fails with SIGPIPE every time instead of now and then.
cat >"$work/bin/ip" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-o -4 addr show")
    echo "1: lo    inet 127.0.0.1/8 scope host lo"
    echo "2: eth0    inet 10.213.1.3/24 brd 10.213.1.255 scope global eth0"
    echo "3: eth1    inet 172.30.0.5/24 brd 172.30.0.255 scope global eth1"
    sleep 0.2
    echo "4: eth2    inet 192.168.9.2/24 brd 192.168.9.255 scope global eth2"
    ;;
  "route get 10.213.1.9") echo "10.213.1.9 dev eth0 src 10.213.1.3 uid 0" ;;
  "route get "*) echo "${3} dev eth1 src 172.30.0.5 uid 0"; sleep 0.2; echo "    cache" ;;
esac
STUB
cat >"$work/bin/tc" <<'STUB'
#!/usr/bin/env bash
echo "tc $*" >>"$LOG"
case "$*" in
  "qdisc show dev eth1")
    echo "qdisc prio 1: root refcnt 2 bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
    echo "qdisc netem 40: parent 1:4 limit 100000 delay 15ms"
    ;;
  "filter show dev eth1 parent 1:")
    echo "filter protocol ip pref 1 u32 chain 0 fh 800::800 order 2048 key ht 800 bkt 0 flowid 1:4"
    echo "  match ac1e0002/ffffffff at 16"
    echo "filter protocol ip pref 1 u32 chain 0 fh 800::801 order 2049 key ht 800 bkt 0 flowid 1:4"
    echo "  match ac1e000c/ffffffff at 16"
    ;;
esac
STUB
cat >"$work/bin/ping" <<'STUB'
#!/usr/bin/env bash
for t in 15.2 14.9 15.1 16.0 15.0; do echo "64 bytes from x: icmp_seq=1 ttl=64 time=$t ms"; done
STUB
# curl -w '%{time_connect} %{time_starttransfer}': three calls, then failures
# once $work/curl-down exists.
cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ ! -f "$WORK/curl-down" ] || exit 7
n="$(cat "$WORK/curl-n" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$WORK/curl-n"
case "$n" in 0) printf '0.015200 0.030100' ;; 1) printf '0.014900 0.029800' ;; *) printf '0.016000 0.031000' ;; esac
STUB
# iperf3 3.21 client output from the pinned netshoot image, -n 200M -f m.
cat >"$work/bin/iperf3" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
Connecting to host 127.0.0.1, port 5201
[  5] local 127.0.0.1 port 35454 connected to 127.0.0.1 port 5201
[ ID] Interval           Transfer     Bitrate         Retr  Cwnd
[  5]   0.00-1.01   sec   200 MBytes  1667 Mbits/sec    0   1023 KBytes
- - - - - - - - - - - - - - - - - - - - - - - - -
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-1.01   sec   200 MBytes  1668 Mbits/sec    0            sender
[  5]   0.00-1.01   sec   200 MBytes  1667 Mbits/sec                  receiver

iperf Done.
OUT
STUB
export WORK="$work"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

failures=0
check() {
  if eval "$2"; then
    echo "ok: $1"
  else
    echo "FAIL: $1"
    sed 's/^/    /' "$work/out" "$LOG" 2>/dev/null || true
    failures=$((failures + 1))
  fi
}
run() {
  : >"$LOG"
  status=0
  bash -s -- "$@" <"$script" >"$work/out" 2>&1 || status=$?
}

run apply 172.30.0.5 15 172.30.0.2 172.30.0.12
check "apply succeeds" '[ "$status" -eq 0 ]'
check "apply shapes the forge-network interface" 'grep -qx "dev eth1" "$work/out"'
check "apply installs the prio root" 'grep -qx "tc qdisc add dev eth1 root handle 1: prio bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0" "$LOG"'
check "apply installs netem on band 4" 'grep -qx "tc qdisc add dev eth1 parent 1:4 handle 40: netem delay 15ms limit 100000" "$LOG"'
check "apply adds one filter per target address" '[ "$(grep -c "u32 match ip dst 172.30.0.[0-9]*/32 flowid 1:4" "$LOG")" -eq 2 ]'

run apply 172.30.0.5 15 172.30.0.2 10.213.1.9
check "a target address routed by another interface stops apply" '[ "$status" -eq 1 ] && grep -q "route to 10.213.1.9 leaves by eth0" "$work/out"'
check "nothing is installed after a route mismatch" '! grep -q "qdisc add" "$LOG"'

run apply 172.30.0.99 15 172.30.0.2
check "an address no interface holds stops apply" '[ "$status" -eq 1 ] && grep -q "no interface holds 172.30.0.99" "$work/out"'

run show 172.30.0.5
check "show reports the root, the delay and the filters as addresses" \
  '[ "$(tr "\n" " " <"$work/out")" = "dev eth1 root prio delay 15ms filter 172.30.0.2 filter 172.30.0.12 " ]'

run ping 172.30.0.2
check "ping reports received, mean, median and max" '[ "$(cat "$work/out")" = "ping 172.30.0.2 5 15.240 15.1 16.0" ]'

run connect http://172.30.0.2:80/health 3
check "connect reports successes and median connect and first-byte times" '[ "$(cat "$work/out")" = "connect 3 15.200 30.100" ]'
touch "$work/curl-down"
run connect http://172.30.0.2:80/health 3
check "connect with no successful call reports zero" '[ "$status" -eq 0 ] && [ "$(cat "$work/out")" = "connect 0 - -" ]'

run iperf 172.30.0.2 200M
check "iperf reports the receiver rate" '[ "$(cat "$work/out")" = "iperf 1667" ]'

if [ "$failures" -ne 0 ]; then
  echo "netem-apply: $failures failure(s)"
  exit 1
fi
echo "netem-apply: all tests passed"
