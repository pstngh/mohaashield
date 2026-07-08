#!/usr/bin/env bash
# MOHAAShield — preserve the current capture ring so an attack window isn't overwritten.
# Copies (does not move) the live ring files aside; capture continues uninterrupted.
# Prunes old incidents so preserved windows stay disk-bounded.
#   Usage:  /opt/mohaashield/freeze.sh [tag]
set -uo pipefail

CONF="${FLIGHTRECORDER_CONF:-/etc/mohaashield/flightrecorder.conf}"
[ -r "$CONF" ] && . "$CONF"

OUTDIR="${OUTDIR:-/var/lib/mohaashield/pcap}"
DEST_ROOT="${DEST_ROOT:-/var/lib/mohaashield/incidents}"
MAX_INCIDENTS="${MAX_INCIDENTS:-5}"        # keep newest N preserved windows (bounds disk)
TAG="${1:-manual}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$DEST_ROOT/${STAMP}_${TAG}"

shopt -s nullglob
files=("$OUTDIR"/mohaa*.pcapng)
if [ "${#files[@]}" -eq 0 ]; then
  echo "freeze: no capture files in $OUTDIR (is the recorder running?)" >&2
  exit 1
fi

mkdir -p "$DEST"
cp -a "${files[@]}" "$DEST"/
echo "freeze: preserved ${#files[@]} file(s) to $DEST"

# Prune oldest incidents beyond MAX_INCIDENTS so preserved windows can't fill the disk.
mapfile -t old < <(ls -1dt "$DEST_ROOT"/*/ 2>/dev/null | tail -n +$((MAX_INCIDENTS + 1)))
if [ "${#old[@]}" -gt 0 ]; then
  rm -rf "${old[@]}"
  echo "freeze: pruned ${#old[@]} old incident(s), keeping newest $MAX_INCIDENTS"
fi

echo "freeze: inspect with  tshark -r '$DEST/$(basename "${files[-1]}")' -c 50"
