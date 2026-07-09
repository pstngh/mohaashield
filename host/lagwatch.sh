#!/usr/bin/env bash
# MOHAAShield lagwatch — overnight freeze/stall diagnostic. Read-only, bounded.
#
# Once a second it logs system + game state, and it MEASURES ITS OWN scheduling delay: if the
# monitor itself was frozen for a beat, the whole box stalled, and it dumps a detailed snapshot
# (PSI pressure, top procs by core, D-state/blocked procs, kernel tail) so you can tell what
# caused it:
#   lag high + psi_io high / wa% high   -> disk I/O stall
#   lag high + st% high                 -> OVH CPU steal (throttling)
#   lag high + psi_mem high             -> memory reclaim
#   lag LOW but game_ms drops to ~0     -> stall specific to the game's isolated CPU 1
#
#   sudo bash host/lagwatch.sh [hours]        (default 10)
set -uo pipefail

HOURS="${1:-10}"
LAG_FLAG_MS="${LAG_FLAG_MS:-250}"     # a second that ran >=250ms long = a stall worth snapshotting
OUT="/var/log/mohaashield-lagwatch.$(date -u +%Y%m%dT%H%M%SZ).log"
CLK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
END=$(( $(date +%s) + HOURS*3600 ))

exec >>"$OUT" 2>&1
echo "# lagwatch start $(date -u +%FT%TZ)  hours=$HOURS  flag>=${LAG_FLAG_MS}ms"
[ -r /proc/pressure/cpu ] || echo "# note: PSI (/proc/pressure) not available on this kernel"
echo "# per-sec: ts lag_ms wa% st% psi_io_us psi_cpu_us psi_mem_us game_ms load run blk mem_mb"

read_cpu(){ awk '/^cpu /{print $6, $9, ($2+$3+$4+$5+$6+$7+$8+$9)}' /proc/stat; }  # iowait steal total
psi(){ awk -F'total=' -v k="$1" '$0 ~ "^"k {print $2+0; exit}' "$2" 2>/dev/null; }
gticks(){ local p s; p="$(pgrep -x omohaaded | head -1)"; [ -n "$p" ] || { echo 0; return; }
          s="$(cat /proc/"$p"/stat 2>/dev/null)" || { echo 0; return; }
          s=${s#*) }; set -- $s; echo $(( ${12} + ${13} )); }

read -r pi ps pt <<<"$(read_cpu)"
ppcpu="$(psi some /proc/pressure/cpu)"; ppio="$(psi full /proc/pressure/io)"; ppmem="$(psi full /proc/pressure/memory)"
: "${ppcpu:=0}" "${ppio:=0}" "${ppmem:=0}"
pg="$(gticks)"

while [ "$(date +%s)" -lt "$END" ]; do
  t0=$(date +%s.%N); sleep 1; t1=$(date +%s.%N)
  lag=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%d",((b-a)-1)*1000}')
  [ "$lag" -lt 0 ] 2>/dev/null && lag=0

  read -r ci cs ct <<<"$(read_cpu)"
  dtot=$(( ct - pt )); [ "$dtot" -le 0 ] && dtot=1
  wa=$(( (ci-pi)*100/dtot )); st=$(( (cs-ps)*100/dtot )); pi=$ci; ps=$cs; pt=$ct

  cpcpu="$(psi some /proc/pressure/cpu)"; cpio="$(psi full /proc/pressure/io)"; cpmem="$(psi full /proc/pressure/memory)"
  : "${cpcpu:=0}" "${cpio:=0}" "${cpmem:=0}"
  dio=$(( cpio-ppio )); dcpu=$(( cpcpu-ppcpu )); dmem=$(( cpmem-ppmem )); ppcpu=$cpcpu; ppio=$cpio; ppmem=$cpmem
  [ "$dio" -lt 0 ] && dio=0; [ "$dcpu" -lt 0 ] && dcpu=0; [ "$dmem" -lt 0 ] && dmem=0

  cg="$(gticks)"; dgt=$(( cg-pg )); pg=$cg; [ "$dgt" -lt 0 ] && dgt=0; gms=$(( dgt*1000/CLK ))

  load="$(awk '{print $1}' /proc/loadavg)"
  run="$(awk '/^procs_running/{print $2}' /proc/stat)"; blk="$(awk '/^procs_blocked/{print $2}' /proc/stat)"
  mem="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
  ts="$(date -u +%FT%TZ)"

  echo "$ts lag=$lag wa=$wa st=$st psi_io=$dio psi_cpu=$dcpu psi_mem=$dmem game_ms=$gms load=$load run=$run blk=$blk mem=$mem"

  if [ "$lag" -ge "$LAG_FLAG_MS" ]; then
    echo "### STALL $ts lag=${lag}ms wa=${wa}% st=${st}% psi_io=${dio}us psi_cpu=${dcpu}us psi_mem=${dmem}us game_ms=${gms} blk=${blk} ###"
    echo "-- top cpu (pid psr %cpu comm) --"; ps -eo pid,psr,pcpu,comm --sort=-pcpu 2>/dev/null | head -6
    echo "-- blocked / D-state --"; ps -eo stat,pid,psr,comm 2>/dev/null | awk '$1 ~ /D/' | head -6
    echo "-- pressure --"; grep -H . /proc/pressure/* 2>/dev/null | sed 's/^/   /'
    echo "-- kernel tail --"; dmesg 2>/dev/null | tail -3
    echo "###"
  fi
done
echo "# lagwatch end $(date -u +%FT%TZ)"
