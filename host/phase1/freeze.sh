#!/usr/bin/env bash
# MOHAAShield — preserve the current capture ring so an attack window isn't overwritten.
# Copies (does not move) the live ring files aside; capture continues uninterrupted.
#   Usage:  sudo /opt/mohaashield/freeze.sh [tag]
set -euo pipefail

OUTDIR="${OUTDIR:-/var/lib/mohaashield/pcap}"
DEST_ROOT="${DEST_ROOT:-/var/lib/mohaashield/incidents}"
TAG="${1:-manual}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$DEST_ROOT/${STAMP}_${TAG}"

mkdir -p "$DEST"
shopt -s nullglob
files=("$OUTDIR"/mohaa*.pcapng)
if [ "${#files[@]}" -eq 0 ]; then
  echo "no capture files in $OUTDIR (is the recorder running?)"; exit 1
fi
cp -av "${files[@]}" "$DEST"/
echo "Preserved ${#files[@]} file(s) to $DEST"
echo "Inspect with:  tshark -r '$DEST/$(basename "${files[-1]}")' -c 50"
