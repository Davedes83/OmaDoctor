#!/bin/sh
# OmaDoctor network check.
#
# Emits: {"section":"network","checks":[ ... ]}
#   with --checks-only: prints just the JSON array (used by doctor.sh).
#
# Read-only, and deliberately expensive: this is the only section that touches
# the network, so doctor.sh runs it on a FULL scan only, never in the periodic
# quick scan. Every probe has its own hard timeout so a blackholed network
# cannot stall the scan.
#
# ICMP note: ping(1) needs either root or the linux_icmp_permissions sysctl to
# send datagram ICMP unprivileged. When it is unavailable the checks degrade to
# "info" rather than reporting a false failure -- an unknown result is not the
# same as a bad one.
# bootstrap.sh is sourced FIRST so that running this section directly -- which
# is exactly what its own failure messages tell the user to do -- gets the
# same pinned PATH, umask and locale as a dispatcher-driven run. Without it,
# a shadow executable anywhere on the caller's PATH is resolved here.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

MODE=${1:-}
CHECKS=""

# ping_probe HOST LABEL -> sets PING_OK, PING_LOSS, PING_AVG, PING_RAW
ping_probe() {
  _host=$1
  PING_OK=0
  PING_LOSS=""
  PING_AVG=""
  PING_RAW=""

  have ping || { PING_RAW="ping not installed"; return 0; }

  # 3 packets, 0.3s interval (above the unprivileged 0.2s floor), 2s per-packet
  # timeout: ~2s worst case. LC_ALL=C guarantees English statistics output.
  out=$(/usr/bin/timeout -k 1 6 ping -n -q -c 3 -i 0.3 -W 2 "$_host" 2>/dev/null)
  [ -n "$out" ] || { PING_RAW="no reply"; return 0; }

  loss=$(printf '%s\n' "$out" | /usr/bin/sed -n 's/.*[, ]\([0-9]\{1,3\}\)% packet loss.*/\1/p' | /usr/bin/head -n 1)
  avg=$(printf '%s\n' "$out" | /usr/bin/sed -n 's|.*=\(.*\)/\([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\).*|\2|p' | /usr/bin/head -n 1)
  sent=$(printf '%s\n' "$out" | /usr/bin/sed -n 's/^\([0-9]\+\) packets transmitted.*/\1/p' | /usr/bin/head -n 1)
  recv=$(printf '%s\n' "$out" | /usr/bin/sed -n 's/.*[, ]\([0-9]\+\) received.*/\1/p' | /usr/bin/head -n 1)

  PING_RAW="sent=${sent:-?} received=${recv:-?} loss=${loss:-?}%"
  case "$loss" in
    '' | *[!0-9]*)
      # ICMP blocked or no permission: report unknown, not failed.
      PING_RAW="${PING_RAW} (ICMP unavailable -- treating as unknown)"
      return 0
      ;;
  esac

  PING_LOSS=$loss
  PING_AVG=$avg
  [ "${recv:-0}" -gt 0 ] 2>/dev/null && PING_OK=1
  return 0
}

# ------------------------------------------------------------------- interfaces
ifaces=""
if have ip; then
  ifaces=$(/usr/bin/ip -o link show 2>/dev/null \
            | /usr/bin/awk -F': ' '$2 !~ /^(lo|veth|docker|br-|virbr|zt|tun)/ {print $2}' \
            | /usr/bin/tr '\n' ' ')
fi

if [ -z "$(printf '%s' "$ifaces" | /usr/bin/tr -d ' ')" ]; then
  emit "network.interfaces" network info 0 "Interfaces" "none detected" \
    "no non-virtual interfaces found" \
    "Check that a network device is present (ip link)."
else
  emit "network.interfaces" network ok 0 "Interfaces" "$(printf '%s' "$ifaces" | /usr/bin/sed 's/ *$//')" \
    "active non-virtual interfaces" ""
fi

# ----------------------------------------------------------------- default route
gw=""
if have ip; then
  gw=$(/usr/bin/ip -4 route show default 2>/dev/null | /usr/bin/awk '/default/ {print $3; exit}')
fi
if [ -z "$gw" ]; then
  emit "network.route" network problem 3 "Default route" "missing" \
    "no IPv4 default route" \
    "The machine has no path off-subnet. Check the connection or NetworkManager."
else
  emit "network.route" network ok 0 "Default route" "$gw" \
    "IPv4 gateway" ""
fi

# ------------------------------------------------------------------- IPv4 address
ipv4=""
if have ip; then
  ipv4=$(/usr/bin/ip -4 -o addr show scope global 2>/dev/null \
         | /usr/bin/awk '{split($4,a,"/"); print a[1]; exit}')
fi
if [ -z "$ipv4" ]; then
  emit "network.ipv4" network attention 1 "IPv4 address" "none" \
    "no global-scope IPv4 address" \
    "You may be on IPv6-only, or the interface lost its lease. Reconnect the network."
else
  emit "network.ipv4" network ok 0 "IPv4 address" "$ipv4" \
    "global scope" ""
fi

# ------------------------------------------------------------------- IPv6
ipv6=""
if have ip; then
  ipv6=$(/usr/bin/ip -6 -o addr show scope global 2>/dev/null \
         | /usr/bin/awk '{split($4,a,"/"); print a[1]; exit}')
fi
if [ -n "$ipv6" ]; then
  emit "network.ipv6" network ok 0 "IPv6" "$ipv6" "global scope" ""
else
  emit "network.ipv6" network info 0 "IPv6" "none" \
    "no global-scope IPv6 address" \
    "Fine on IPv4-only or LAN-only setups."
fi

# ------------------------------------------------------------------- DNS config
if have resolvectl; then
  dns_srv=$(/usr/bin/timeout -k 1 3 resolvectl dns 2>/dev/null \
            | /usr/bin/sed -n 's/.*: //p' | /usr/bin/tr ' ' '\n' | /usr/bin/grep -c . || true)
elif [ -r /etc/resolv.conf ]; then
  dns_srv=$(/usr/bin/grep -c '^nameserver' /etc/resolv.conf 2>/dev/null || true)
else
  dns_srv=0
fi
case "$dns_srv" in '' | *[!0-9]*) dns_srv=0 ;; esac
if [ "$dns_srv" -gt 0 ]; then
  emit "network.dns_config" network ok 0 "DNS servers" "$dns_srv configured" \
    "resolver configuration present" ""
else
  emit "network.dns_config" network problem 3 "DNS servers" "none" \
    "no nameserver configured" \
    "Name resolution will fail. Restore a resolver in /etc/resolv.conf or NetworkManager."
fi

# ------------------------------------------------------------------- DNS resolve
if have getent; then
  dns_probe=$(/usr/bin/timeout -k 1 5 getent hosts omarchy.org 2>/dev/null | /usr/bin/head -n 1)
  case "$dns_probe" in
    '')
      emit "network.dns" network problem 3 "DNS resolution" "failed" \
        "could not resolve omarchy.org" \
        "Names do not resolve even though servers are configured. Try: resolvectl query omarchy.org"
      ;;
    *)
      emit "network.dns" network ok 0 "DNS resolution" "working" \
        "omarchy.org resolved" ""
      ;;
  esac
else
  emit "network.dns" network info 0 "DNS resolution" "unknown" \
    "getent unavailable" ""
fi

# ------------------------------------------------------------------- gateway reach
if [ -n "$gw" ]; then
  ping_probe "$gw"
  if [ "$PING_OK" = "1" ]; then
    emit "network.gateway" network ok 0 "Gateway" "$PING_AVG ms" "$PING_RAW" ""
  elif [ -z "$PING_LOSS" ]; then
    emit "network.gateway" network info 0 "Gateway" "unreachable (ICMP blocked)" \
      "$PING_RAW" ""
  else
    emit "network.gateway" network problem 3 "Gateway" "unreachable" \
      "$PING_RAW" \
      "The gateway does not answer. The link is up but nothing off-subnet works."
  fi
else
  emit "network.gateway" network info 0 "Gateway" "unknown" \
    "no gateway to probe" ""
fi

# ------------------------------------------------------------------- internet reach
ping_probe "1.1.1.1"
if [ "$PING_OK" = "1" ]; then
  if [ -n "$PING_LOSS" ] && [ "$PING_LOSS" -gt 0 ] 2>/dev/null; then
    emit "network.internet" network attention 1 "Internet" "$PING_LOSS% loss" \
      "$PING_RAW, avg $PING_AVG ms" \
      "Reachable but lossy. Common on Wi-Fi: check signal strength and router."
  else
    emit "network.internet" network ok 0 "Internet" "reachable" \
      "$PING_RAW, avg $PING_AVG ms" ""
  fi
elif [ -z "$PING_LOSS" ]; then
  emit "network.internet" network info 0 "Internet" "unknown (ICMP blocked)" \
    "$PING_RAW" ""
else
  emit "network.internet" network problem 3 "Internet" "unreachable" \
    "$PING_RAW" \
    "Gateway is fine but the internet is not. DNS worked, so check routing/firewall."
fi

# ------------------------------------------------------------------- latency
if [ -n "$PING_AVG" ]; then
  case "$PING_AVG" in
    '' | *[!0-9.]*) ;;
    *)
      # Use awk for the float comparison: POSIX sh has no floating point.
      slow=$(printf '%s' "$PING_AVG" | /usr/bin/awk '{print ($1 > 120) ? 1 : 0}')
      if [ "$slow" = "1" ]; then
        emit "network.latency" network attention 1 "Latency" "$PING_AVG ms" \
          "average round-trip to 1.1.1.1" \
          "Above ~120 ms feels sluggish to video calls and game streaming."
      else
        emit "network.latency" network ok 0 "Latency" "$PING_AVG ms" \
          "average round-trip to 1.1.1.1" ""
      fi
      ;;
  esac
else
  # PING_AVG is empty in three ordinary situations: ping is not installed, ping
  # produced no parsable output, or ICMP is blocked. On a default-deny firewall
  # that is the NORMAL state, and this is exactly where a latency reading would
  # be most useful -- so the check must be reported as unavailable, not dropped.
  # Silently omitting it makes "latency is fine" and "latency is unknown"
  # indistinguishable in the summary counts.
  emit "network.latency" network info 0 "Latency" "unavailable" \
    "ICMP is blocked or ping(8) is not installed" \
    "Latency needs ICMP; a blocked firewall usually explains this"
fi

emit_json network "$MODE"
