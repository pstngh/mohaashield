#!/usr/bin/env bash
# MOHAAShield — preserve the recent capture window so an attack isn't overwritten.
# Copies only the NEWEST few ring files (not the whole ~2 GB ring) at idle I/O priority,
# so a freeze can't stall the game. Copies (doesn't move); capture continues uninterrupted.
# Prunes old incidents so preserved windows stay disk-bounded.
#   Usage:  /opt/mohaashield/freeze.sh [tag]
set -uo pipefail

CONF="${FLIGHTRECORDER_CONF:-/etc/mohaashield/flightrecorder.conf}"
[ -r "$CONF" ] && . "$CONF"

OUTDIR="${OUTDIR:-/var/lib/mohaashield/pcap}"
DEST_ROOT="${DEST_ROOT:-/var/lib/mohaashield/incidents}"
MAX_INCIDENTS="${MAX_INCIDENTS:-5}"        # keep newest N preserved windows (bounds disk)
FREEZE_FILES="${FREEZE_FILES:-8}"          # copy only the newest N ring files (bounds I/O)
TAG="${1:-manual}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$DEST_ROOT/${STAMP}_${TAG}"

# newest FREEZE_FILES ring files only — a big ring copy is what stalled the box
mapfile -t files < <(ls -1t "$OUTDIR"/mohaa*.pcapng 2>/dev/null | head -n "$FREEZE_FILES")
if [ "${#files[@]}" -eq 0 ]; then
  echo "freeze: no capture files in $OUTDIR (is the recorder running?)" >&2
  exit 1
fi

mkdir -p "$DEST"

# idle I/O priority so the copy yields the disk to the game
IONICE=""
command -v ionice >/dev/null 2>&1 && IONICE="ionice -c 3"
$IONICE cp -a "${files[@]}" "$DEST"/
echo "freeze: preserved ${#files[@]} newest file(s) to $DEST"

# prune oldest incidents beyond MAX_INCIDENTS so preserved windows can't fill the disk
mapfile -t old < <(ls -1dt "$DEST_ROOT"/*/ 2>/dev/null | tail -n +$((MAX_INCIDENTS + 1)))
if [ "${#old[@]}" -gt 0 ]; then
  rm -rf "${old[@]}"
  echo "freeze: pruned ${#old[@]} old incident(s), keeping newest $MAX_INCIDENTS"
fi

echo "freeze: inspect the largest slice with:"
echo "  sudo bash -c 'f=\$(ls -1S \"$DEST\"/*.pcapng | head -1); capinfos -c -u -x \"\$f\"; tshark -r \"\$f\" -q -z conv,udp | head'"
