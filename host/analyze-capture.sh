#!/usr/bin/env bash
# MOHAAShield — characterize a preserved capture: WHO and WHAT is flooding the game ports,
# and crucially whether it's connectionless (OOB, our rule catches it) or not (it doesn't).
# Read-only. Auto-picks the largest pcap in the newest incident, or takes a file/dir argument.
#   sudo bash host/analyze-capture.sh [pcap-file | incident-dir]
set -uo pipefail
command -v tshark >/dev/null 2>&1 || { echo "tshark not installed: sudo apt install -y tshark"; exit 1; }

INC="${DEST_ROOT:-/var/lib/mohaashield/incidents}"
ARG="${1:-}"
if [ -z "$ARG" ]; then
  d="$(ls -1dt "$INC"/*/ 2>/dev/null | head -1)"; [ -n "$d" ] || { echo "no incidents in $INC"; exit 1; }
  F="$(ls -1S "$d"/*.pcapng 2>/dev/null | head -1)"
elif [ -d "$ARG" ]; then
  F="$(ls -1S "$ARG"/*.pcapng 2>/dev/null | head -1)"
else
  F="$ARG"
fi
[ -r "${F:-}" ] || { echo "no readable pcap found (${F:-none})"; exit 1; }
echo "== analyzing $F =="

# Inbound to the game only (dstport) — excludes the server's own reply packets.
IN='(udp.dstport==12203 || udp.dstport==12300)'
OOB='udp.payload[0:4]==ff:ff:ff:ff'
tsh(){ nice -n 10 tshark -r "$F" "$@" 2>/dev/null; }

echo; echo "-- capture window --"
capinfos -c -u -a -e "$F" 2>/dev/null | grep -Ei 'number of pack|duration|first pack|last pack' | sed 's/^/  /'

tot=$(tsh -Y "$IN" | wc -l)
oob=$(tsh -Y "$IN && $OOB" | wc -l)
seq=$(( tot - oob ))
echo; echo "-- inbound packets to game ports --"
printf '  %-10s %s\n' "total"   "$tot"
printf '  %-10s %s   %s\n' "OOB"     "$oob" "(connectionless — our per-source rule limits these)"
printf '  %-10s %s   %s\n' "non-OOB" "$seq" "(NOT ffffffff — our rule ignores these entirely)"

echo; echo "-- top source IPs, ALL inbound (unique-source count tells few-source vs distributed) --"
tsh -Y "$IN" -T fields -e ip.src | sort | uniq -c | sort -rn | head -15 | sed 's/^/  /'
uniq_all=$(tsh -Y "$IN" -T fields -e ip.src | sort -u | wc -l)
echo "  distinct source IPs (all inbound): $uniq_all"

echo; echo "-- top source IPs, OOB only --"
tsh -Y "$IN && $OOB" -T fields -e ip.src | sort | uniq -c | sort -rn | head -15 | sed 's/^/  /'
uniq_oob=$(tsh -Y "$IN && $OOB" -T fields -e ip.src | sort -u | wc -l)
echo "  distinct OOB source IPs: $uniq_oob   <-- MANY (thousands) = distributed OOB flood our per-source rule can't fully stop"

echo; echo "-- OOB command breakdown --"
for c in connect getstatus getchallenge getinfo authorizeThis rcon disconnect; do
  n=$(tsh -Y "$IN && $OOB && udp contains \"$c\"" | wc -l)
  [ "$n" -gt 0 ] && printf '  %-14s %s\n' "$c" "$n"
done

if [ "$seq" -gt 0 ]; then
  echo; echo "-- non-OOB flood sources (if this is large, it's a junk/reflection vector, NOT connectionless) --"
  tsh -Y "$IN && !($OOB)" -T fields -e ip.src | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'
fi

echo; echo "-- inbound pps over time (1s bins, last 20s of the window) --"
tsh -Y "$IN" -q -z io,stat,1 | grep -E '<>|[0-9]+ <' | tail -20 | sed 's/^/  /'

echo; echo "== read: high 'distinct OOB source IPs' => distributed OOB (needs a global gate, not per-source)."
echo "         large 'non-OOB' => junk/reflection flood (needs a rule that doesn't rely on the ffffffff marker)."
