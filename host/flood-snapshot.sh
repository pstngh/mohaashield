#!/usr/bin/env bash
# MOHAAShield — live snapshot during a flood: is the game CPU-bound, or STARVED by the flood's
# packet-processing (softirq) on a shared core? Read-only, ~3s, no extra packages.
#   sudo bash host/flood-snapshot.sh
set -uo pipefail
CLK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
PID="$(pgrep -x omohaaded | head -1)"
gt(){ [ -n "$PID" ] || { echo 0; return; }; local x; x="$(cat /proc/$PID/stat 2>/dev/null)" || { echo 0; return; }
      x=${x#*) }; set -- $x; echo $(( ${12} + ${13} )); }
nd(){ nft list chain inet mohaashield oob_ratelimit 2>/dev/null | grep -oE 'packets [0-9]+' | awk '{s=$2} END{print s+0}'; }
core_snap(){ awk '/^cpu[0-9]+ /{print $1,$2,$4,$8,$5,($2+$3+$4+$5+$6+$7+$8+$9)}' /proc/stat; }  # core user sys soft idle total

declare -A U S SO ID T
while read -r c u s so id t; do U[$c]=$u; S[$c]=$s; SO[$c]=$so; ID[$c]=$id; T[$c]=$t; done < <(core_snap)
g0="$(gt)"; d0="$(nd)"
sleep 3
g1="$(gt)"; d1="$(nd)"

echo "== game process =="
if [ -n "$PID" ]; then
  psr="$(ps -o psr= -p "$PID" 2>/dev/null | tr -d ' ')"
  echo "  pid=$PID  on CPU $psr  game_cpu=$(( (g1-g0)*1000/CLK/3 )) ms/sec   (1000 = a full core)"
else
  echo "  omohaaded not running"; psr="?"
fi

echo "== per-core CPU over 3s  (soft% = softirq = kernel network packet processing) =="
printf '  %-6s %6s %6s %7s %6s\n' core usr sys soft idle
GSOFT=0; GIDLE=100
while read -r c u s so id t; do
  dt=$(( t - ${T[$c]:-0} )); [ "$dt" -le 0 ] && dt=1
  cso=$(( (so-${SO[$c]:-0})*100/dt )); cid=$(( (id-${ID[$c]:-0})*100/dt ))
  mark=""; if [ "cpu${psr}" = "$c" ]; then mark="   <- game"; GSOFT=$cso; GIDLE=$cid; fi
  printf '  %-6s %5s%% %5s%% %6s%% %5s%%%s\n' "$c" \
    $(( (u-${U[$c]:-0})*100/dt )) $(( (s-${S[$c]:-0})*100/dt )) "$cso" "$cid" "$mark"
done < <(core_snap)

DROP=$(( (d1 - d0) / 3 )); GMS=$(( (g1-g0)*1000/CLK/3 ))
echo "== nft OOB drop rate =="
echo "  ~${DROP} OOB packets/sec dropped right now"

echo
# Data-driven verdict (not a fixed message) so it can't contradict the numbers above.
if [ "$DROP" -lt 200 ] && [ "$GSOFT" -lt 15 ]; then
  echo "VERDICT: no active flood this instant (dropping ~${DROP} pps, game-core softirq ${GSOFT}%)."
  echo "  Box is calm, game (${GMS} ms/sec) healthy. The flood is intermittent — re-run DURING a"
  echo "  jitter episode (or when the drop rate is high) to catch the mechanism live."
elif [ "$GMS" -ge 800 ]; then
  echo "VERDICT: the game itself is CPU-bound (${GMS} ms/sec ~ a full core) — it's chewing on load"
  echo "  that reached it, not just being interrupted. Look at what's getting THROUGH the drop rules."
elif [ "$GSOFT" -ge 15 ]; then
  echo "VERDICT: flood active and its softirq (${GSOFT}% on the game's core CPU ${psr}) is starving the"
  echo "  single-threaded game (${GMS} ms/sec, core ${GIDLE}% idle) — that's the jitter. If not already"
  echo "  pinned: sudo bash host/cpu-isolation/pin-runtime.sh   (then re-run; game-core soft% should fall)."
else
  echo "VERDICT: mixed signal — drop ~${DROP} pps, game-core soft ${GSOFT}%, game ${GMS} ms/sec."
  echo "  Re-run during a clear jitter episode for a cleaner read."
fi
