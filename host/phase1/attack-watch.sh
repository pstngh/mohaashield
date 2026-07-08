#!/usr/bin/env bash
# MOHAAShield attack-watch — auto-freeze the pcap ring when traffic spikes.
#
# Edge-triggered: freezes ONCE when traffic crosses the threshold (attack start), re-snapshots
# a still-ongoing attack at most every WATCH_MAX_HOLD seconds, and re-arms after traffic has
# been calm for WATCH_REARM_QUIET seconds. State is persisted so a restart can't cause a
# re-freeze storm.
#
# OBSERVE-ONLY: it copies pcap aside, never drops/bans. Runs as the unprivileged 'mohaashield'
# user (reads /sys, runs freeze.sh).
set -uo pipefail

CONF="${FLIGHTRECORDER_CONF:-/etc/mohaashield/flightrecorder.conf}"
[ -r "$CONF" ] && . "$CONF"

IFACE="${IFACE:-ens3}"
INTERVAL="${WATCH_INTERVAL:-2}"
PPS_TRIGGER="${WATCH_PPS_TRIGGER:-4000}"
DROP_TRIGGER="${WATCH_DROP_TRIGGER:-1}"
REARM_QUIET="${WATCH_REARM_QUIET:-60}"      # seconds below threshold before re-arming
MAX_HOLD="${WATCH_MAX_HOLD:-1800}"          # re-snapshot an ongoing attack at most this often
FREEZE="${FREEZE:-/opt/mohaashield/freeze.sh}"
INC="${DEST_ROOT:-/var/lib/mohaashield/incidents}"
STATE="$INC/.attackwatch.state"
STAT="/sys/class/net/${IFACE}/statistics"

[ -d "$STAT" ] || { echo "attack-watch: no such interface stats: $STAT" >&2; exit 1; }

read_val()  { cat "$STAT/$1" 2>/dev/null || echo 0; }
read_drops(){ echo $(( $(read_val rx_dropped) + $(read_val rx_missed_errors) + $(read_val rx_fifo_errors) )); }
save_state(){ printf 'armed=%s\nlast_freeze=%s\nquiet_since=%s\n' "$armed" "$last_freeze" "$quiet_since" > "$STATE" 2>/dev/null || true; }

# restore state across restarts (defaults if absent/corrupt)
armed=1; last_freeze=0; quiet_since=0
# shellcheck disable=SC1090
[ -r "$STATE" ] && { . "$STATE" 2>/dev/null || { armed=1; last_freeze=0; quiet_since=0; }; }

last_rx="$(read_val rx_packets)"
last_drop="$(read_drops)"
echo "attack-watch: iface=$IFACE trigger=${PPS_TRIGGER}pps rearm_quiet=${REARM_QUIET}s max_hold=${MAX_HOLD}s (armed=$armed)"

while sleep "$INTERVAL"; do
  now="$(date +%s)"
  rx="$(read_val rx_packets)"; drop="$(read_drops)"
  pps=$(( (rx - last_rx) / INTERVAL )); dd=$(( drop - last_drop ))
  last_rx="$rx"; last_drop="$drop"

  spike=0; reason=""
  [ "$pps" -ge "$PPS_TRIGGER" ] && { spike=1; reason="rx_pps=${pps}"; }
  [ "$dd"  -ge "$DROP_TRIGGER" ] && { spike=1; reason="${reason:+$reason,}nic_drops+=${dd}"; }

  if [ "$spike" = 1 ]; then
    quiet_since=0
    if [ "$armed" = 1 ]; then
      echo "attack-watch: ATTACK START ($reason) -> preserving pcap window"
      "$FREEZE" "auto" || echo "attack-watch: freeze.sh failed" >&2
      armed=0; last_freeze="$now"
    elif [ $(( now - last_freeze )) -ge "$MAX_HOLD" ]; then
      echo "attack-watch: attack ongoing ($reason) -> periodic snapshot"
      "$FREEZE" "auto" || echo "attack-watch: freeze.sh failed" >&2
      last_freeze="$now"
    fi
  elif [ "$armed" = 0 ]; then
    [ "$quiet_since" = 0 ] && quiet_since="$now"
    if [ $(( now - quiet_since )) -ge "$REARM_QUIET" ]; then
      echo "attack-watch: traffic back to normal -> re-armed"
      armed=1; quiet_since=0
    fi
  fi
  save_state
done
