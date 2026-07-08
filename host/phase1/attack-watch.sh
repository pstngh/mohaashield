#!/usr/bin/env bash
# MOHAAShield attack-watch — auto-freeze the pcap ring when traffic spikes.
#
# Purpose: the ring wraps in ~1 min under a full flood, so an unattended attack can be
# overwritten before anyone runs freeze.sh. This watcher samples interface RX pps and NIC
# drop counters and calls freeze.sh on a spike, preserving the attack window.
#
# OBSERVE-ONLY: it copies pcap aside. It NEVER drops or bans traffic. Because a false
# CAPTURE trigger is harmless (per project philosophy), the thresholds are deliberately
# sensitive. Runs as the unprivileged 'mohaashield' user (reads /sys, runs freeze.sh).
set -uo pipefail

CONF="${FLIGHTRECORDER_CONF:-/etc/mohaashield/flightrecorder.conf}"
[ -r "$CONF" ] && . "$CONF"

IFACE="${IFACE:-ens3}"
INTERVAL="${WATCH_INTERVAL:-2}"
PPS_TRIGGER="${WATCH_PPS_TRIGGER:-4000}"
DROP_TRIGGER="${WATCH_DROP_TRIGGER:-1}"
COOLDOWN="${WATCH_COOLDOWN:-300}"
FREEZE="${FREEZE:-/opt/mohaashield/freeze.sh}"
STAT="/sys/class/net/${IFACE}/statistics"

[ -d "$STAT" ] || { echo "attack-watch: no such interface stats: $STAT" >&2; exit 1; }

read_val()  { cat "$STAT/$1" 2>/dev/null || echo 0; }
read_drops(){ echo $(( $(read_val rx_dropped) + $(read_val rx_missed_errors) + $(read_val rx_fifo_errors) )); }

last_rx="$(read_val rx_packets)"
last_drop="$(read_drops)"
last_freeze=0

echo "attack-watch: iface=$IFACE interval=${INTERVAL}s pps_trigger=$PPS_TRIGGER drop_trigger=$DROP_TRIGGER cooldown=${COOLDOWN}s"

while sleep "$INTERVAL"; do
  rx="$(read_val rx_packets)"
  drop="$(read_drops)"
  pps=$(( (rx - last_rx) / INTERVAL ))
  dd=$(( drop - last_drop ))
  last_rx="$rx"; last_drop="$drop"

  reason=""
  [ "$pps" -ge "$PPS_TRIGGER" ] && reason="rx_pps=${pps}"
  [ "$dd"  -ge "$DROP_TRIGGER" ] && reason="${reason:+$reason,}nic_drops+=${dd}"
  [ -n "$reason" ] || continue

  now="$(date +%s)"
  if [ $(( now - last_freeze )) -lt "$COOLDOWN" ]; then
    echo "attack-watch: spike ($reason) within cooldown, not re-freezing"
    continue
  fi
  last_freeze="$now"
  echo "attack-watch: SPIKE ($reason) -> preserving pcap window"
  "$FREEZE" "auto" || echo "attack-watch: freeze.sh failed" >&2
done
