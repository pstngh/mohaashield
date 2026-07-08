#!/usr/bin/env bash
# MOHAAShield — "was I attacked?" report. Read-only. Run each morning.
#   sudo bash host/check.sh [hours]     (default 16)
set -uo pipefail
HOURS="${1:-16}"
SINCE="${HOURS} hours ago"
[ -r /etc/mohaashield/flightrecorder.conf ] && . /etc/mohaashield/flightrecorder.conf
IFACE="${IFACE:-$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')}"
INC="${DEST_ROOT:-/var/lib/mohaashield/incidents}"
hr(){ printf '\n=== %s ===\n' "$1"; }

# ---- gather the primary signals ----
SPIKES="$(journalctl -u mohaashield-attack-watch --since "$SINCE" --no-pager 2>/dev/null | grep -i 'SPIKE' || true)"
RECENT_INC="$(find "$INC" -maxdepth 1 -mindepth 1 -type d -mmin -$((HOURS*60)) 2>/dev/null | sort || true)"
RESTARTS="$(journalctl -u mohaa --since "$SINCE" --no-pager 2>/dev/null | grep -c 'Started' || echo 0)"

# ---- verdict first ----
if [ -n "$SPIKES" ] || [ -n "$RECENT_INC" ]; then
  printf '\n#### ⚠  LIKELY ATTACK in the last %sh — traffic/drop spike caught and pcap preserved.\n' "$HOURS"
elif [ "${RESTARTS:-0}" -gt 1 ]; then
  printf '\n#### ⚠  Game restarted %s times in the last %sh — possible crash under load; investigate.\n' "$RESTARTS" "$HOURS"
else
  printf '\n#### ✓  Quiet — no auto-freeze, no incidents in the last %sh.\n' "$HOURS"
fi

hr "attack-watch (auto-freeze) triggers, last ${HOURS}h"
if ! systemctl is-active --quiet mohaashield-attack-watch; then
  echo "  watcher NOT running! -> systemctl status mohaashield-attack-watch"
elif [ -n "$SPIKES" ]; then
  echo "$SPIKES" | sed 's/^/  /'
else
  echo "  none (watcher active, saw no pps/drop spike)"
fi

hr "preserved incident windows"
if [ -n "$RECENT_INC" ]; then
  echo "  frozen in the last ${HOURS}h:"; ls -lhtd $RECENT_INC | sed 's/^/  /'
else
  echo "  none in the last ${HOURS}h. Most recent saved:"
  ls -1td "$INC"/*/ 2>/dev/null | head -3 | sed 's/^/  /' || echo "  (none yet)"
fi

hr "NIC counters on ${IFACE} (cumulative since boot)"
read -r _b rxp rxe rxd rxm _c <<<"$(ip -s link show "$IFACE" 2>/dev/null | grep -A1 'RX:' | tail -1)"
echo "  RX packets=${rxp:-?} errors=${rxe:-?} dropped=${rxd:-?} missed=${rxm:-?}"
echo "  (nonzero dropped/missed = the NIC shed packets under load at some point)"

hr "nftables counters (accepted vs dropped)"
if command -v nft >/dev/null 2>&1; then
  nft list table inet mohaashield 2>/dev/null | grep -E 'counter packets' | sed 's/^ */  /' || echo "  (no mohaashield table)"
else
  echo "  nft not available"
fi

hr "game server"
if systemctl list-unit-files 2>/dev/null | grep -q '^mohaa\.service'; then
  echo "  state=$(systemctl is-active mohaa)  up_since=$(systemctl show -p ActiveEnterTimestamp --value mohaa 2>/dev/null)"
  echo "  service (re)starts in last ${HOURS}h: ${RESTARTS}  (repeated = crashing, often under attack)"
else
  echo "  mohaa.service not installed (screen/cron launch)"
fi

hr "dig deeper into the newest capture"
newest="$(ls -1t "$INC"/*/*.pcapng 2>/dev/null | head -1 || true)"
if [ -n "$newest" ]; then
  echo "  sudo tshark -r '$newest' -q -z conv,udp | head -25          # top talkers"
  echo "  sudo tshark -r '$newest' -q -z io,stat,1 | tail -20         # pps over time"
else
  echo "  (no captures preserved yet)"
fi
