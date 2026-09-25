#!/usr/bin/env bash
# Runs inside the netshoot sidecar that scripts/host/netem.sh starts in a
# container's network namespace, fed on stdin (`bash -s -- <mode> ...`). It has
# no host dependencies: only ip, tc, ping, curl and iperf3 from the image.
#
#   apply <ip> <rtt-ms> <central-ip>...  prio qdisc, netem on band 4, one u32
#                                        filter per central address
#   show <ip>                            dev, root qdisc kind, netem delay, filters
#   clear <ip>                           remove the root qdisc
#   ping <target-ip>...                  20 pings each, in parallel
#   connect <url> <count>                curl connect and first-byte times
#   iperf <server-ip> <bytes>            iperf3 client; prints Mbit/s received
#
# The interface is the one holding <ip>, the container's forge-network address:
# piri-0 also sits on piri-storage-net, and Docker decides the order.
set -euo pipefail

die() { echo "netem-apply: $*" >&2; exit 1; }

dev_for() {
  ip -o -4 addr show | awk -v ip="$1" '{ split($4, a, "/"); if (a[1] == ip) { sub(/@.*/, "", $2); print $2; exit } }'
}

# median: the middle value of the numbers on stdin, or empty.
median() {
  sort -g | awk '{ v[NR] = $1 } END { if (NR) print (NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2) }'
}

mode="${1:-}"
shift || true

case "$mode" in
  apply | show | clear)
    self="${1:-}"
    [ -n "$self" ] || die "$mode: no address given"
    dev="$(dev_for "$self")"
    [ -n "$dev" ] || die "no interface holds $self"
    ;;
esac

case "$mode" in
  apply)
    rtt="$2"
    shift 2
    [ "$#" -gt 0 ] || die "apply: no central addresses"
    for c in "$@"; do
      via="$(ip route get "$c" | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
      [ "$via" = "$dev" ] || die "route to $c leaves by ${via:-nothing}, not $dev"
    done
    tc qdisc del dev "$dev" root 2>/dev/null || true
    # The all-zero priomap keeps unfiltered traffic in band 1; only the
    # filters below send traffic to band 4 and its netem.
    tc qdisc add dev "$dev" root handle 1: prio bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    tc qdisc add dev "$dev" parent 1:4 handle 40: netem delay "${rtt}ms" limit 100000
    for c in "$@"; do
      tc filter add dev "$dev" parent 1: protocol ip prio 1 u32 match ip dst "$c/32" flowid 1:4
    done
    echo "dev $dev"
    ;;
  show)
    echo "dev $dev"
    tc qdisc show dev "$dev" | awk '
      $3 == "1:" && $4 == "root" { print "root " $2 }
      $2 == "netem" { for (i = 1; i < NF; i++) if ($i == "delay") print "delay " $(i + 1) }'
    # u32 prints each match as hex address/mask at offset 16 (the IPv4 dst).
    tc filter show dev "$dev" parent 1: | awk '$1 == "match" && $4 == "16" { split($2, m, "/"); print m[1] }' |
      while read -r hex; do
        printf 'filter %d.%d.%d.%d\n' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}" "0x${hex:6:2}"
      done
    ;;
  clear)
    tc qdisc del dev "$dev" root 2>/dev/null || true
    echo "dev $dev"
    ;;
  ping)
    tmp="$(mktemp -d)"
    for t in "$@"; do
      ping -n -c 20 -i 0.2 -W 1 "$t" >"$tmp/$t" 2>&1 &
    done
    wait || true
    # One line per target: received, mean, median and max round trip in ms.
    for t in "$@"; do
      times="$(sed -n 's/.* time=\([0-9.]*\) *ms.*/\1/p' "$tmp/$t")"
      n="$(printf '%s\n' "$times" | grep -c . || true)"
      if [ "$n" -eq 0 ]; then
        echo "ping $t 0 - - -"
        continue
      fi
      mean="$(printf '%s\n' "$times" | awk '{ s += $1 } END { printf "%.3f", s / NR }')"
      max="$(printf '%s\n' "$times" | sort -g | tail -n 1)"
      echo "ping $t $n $mean $(printf '%s\n' "$times" | median) $max"
    done
    rm -rf "$tmp"
    ;;
  connect)
    url="$1" count="$2" ok=0
    : >/tmp/connect
    for _ in $(seq "$count"); do
      if out="$(curl -so /dev/null --max-time 5 -w '%{time_connect} %{time_starttransfer}' "$url")"; then
        echo "$out" >>/tmp/connect
        ok=$((ok + 1))
      fi
    done
    [ "$ok" -gt 0 ] || { echo "connect 0 - -"; exit 0; }
    tcp="$(awk '{ printf "%.3f\n", $1 * 1000 }' /tmp/connect | median)"
    first="$(awk '{ printf "%.3f\n", $2 * 1000 }' /tmp/connect | median)"
    echo "connect $ok $tcp $first"
    ;;
  iperf)
    server="$1" bytes="$2"
    # The server starts in a separate sidecar; retry until it listens.
    for _ in $(seq 20); do
      if out="$(iperf3 -c "$server" -n "$bytes" -f m 2>&1)"; then
        echo "$out" | awk '$NF == "receiver" { for (i = 1; i < NF; i++) if ($(i + 1) == "Mbits/sec") print "iperf " $i }'
        exit 0
      fi
      sleep 0.5
    done
    die "iperf3 could not reach $server"
    ;;
  *)
    die "unknown mode '$mode'"
    ;;
esac
