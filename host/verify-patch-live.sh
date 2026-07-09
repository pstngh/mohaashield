#!/usr/bin/env bash
# MOHAAShield — is the *patched* omohaaded actually LIVE, and is the game still pegging a core?
#
# A rebuilt/edited binary is NOT live until the service restarts — the old process keeps running
# the old code. This checks that (compares the running process to the on-disk binary), then
# samples the game's CPU burn, which is the freeze signature: a single core pegged near 100%
# stalls the single-threaded server and spikes everyone's ping.
#
#   sudo bash host/verify-patch-live.sh
set -uo pipefail
CLK="$(getconf CLK_TCK 2>/dev/null || echo 100)"

PID="$(pgrep -x omohaaded | head -1)"
if [ -z "$PID" ]; then echo "omohaaded is NOT running (pgrep found nothing)."; exit 1; fi

start_str="$(ps -o lstart= -p "$PID" 2>/dev/null | sed 's/^ *//')"
start_epoch="$(date -d "$start_str" +%s 2>/dev/null || echo 0)"
exe_link="$(readlink /proc/"$PID"/exe 2>/dev/null || echo '?')"
bin="${exe_link% (deleted)}"
deleted=0; case "$exe_link" in *" (deleted)") deleted=1;; esac
bin_mtime_epoch="$(stat -c %Y "$bin" 2>/dev/null || echo 0)"

echo "== omohaaded liveness =="
echo "  pid            : $PID"
echo "  running since  : $start_str"
echo "  exe            : $exe_link"
[ "$bin_mtime_epoch" != 0 ] && echo "  on-disk build  : $(date -d "@$bin_mtime_epoch" 2>/dev/null)"
echo

if [ "$deleted" = 1 ]; then
  echo "  >> VERDICT: the running binary was REPLACED on disk after it started."
  echo "     The live process is still the OLD code. Restart to load your patch:"
  echo "         sudo systemctl restart mohaa"
elif [ "$bin_mtime_epoch" -gt "${start_epoch:-0}" ] 2>/dev/null; then
  echo "  >> VERDICT: the on-disk binary is NEWER than the running process."
  echo "     You rebuilt but did not restart — your patch is NOT live yet. Restart:"
  echo "         sudo systemctl restart mohaa"
else
  echo "  >> VERDICT: the running process is not older than the on-disk binary at that path."
  echo "     Looks live. BUT if you built the patch to a DIFFERENT path, the service is still"
  echo "     launching the old one — confirm the path the service runs:"
  echo "         systemctl cat mohaa | grep ExecStart"
fi

echo
echo "== is the game still pegging a core? (10s sample — the freeze signature) =="
read_g(){ local s; s="$(cat /proc/"$PID"/stat 2>/dev/null)" || { echo 0; return; }
          s=${s#*) }; set -- $s; echo $(( ${12} + ${13} )); }
g0="$(read_g)"; sleep 10; g1="$(read_g)"
ms=$(( (g1 - g0) * 1000 / CLK / 10 ))   # avg game CPU-ms per wall-second over the window
echo "  game CPU: ~${ms} ms/sec   (1000 = a full core; sustained >800 = one core pegged = the freeze)"
if [ "$ms" -ge 800 ]; then
  echo "  >> STILL PEGGING. If the patch is confirmed live above, the flood is multi-IP — the"
  echo "     per-source limiter can't collapse it. Add the kernel per-source OOB cap for relief:"
  echo "         sudo bash host/nftables/oob-ratelimit.sh"
else
  echo "  >> not pegging right now (idle between episodes, or the fix is holding)."
  echo "     Re-run this DURING a freeze to catch it."
fi
