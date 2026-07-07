#!/usr/bin/env bash
# MOHAAShield flight recorder launcher (invoked by the systemd unit).
# Always-on, bounded pcap ring of UDP 12203 traffic. Captures only; drops nothing.
set -euo pipefail

: "${IFACE:?set IFACE in /etc/mohaashield/flightrecorder.conf}"
PORT="${PORT:-12203}"
SNAPLEN="${SNAPLEN:-128}"
OUTDIR="${OUTDIR:-/var/lib/mohaashield/pcap}"
RING_FILESIZE_KB="${RING_FILESIZE_KB:-32768}"
RING_FILES="${RING_FILES:-64}"

mkdir -p "$OUTDIR"

# -p : no promiscuous mode (we only want traffic addressed to this host -> needs only CAP_NET_RAW)
# -f : kernel BPF capture filter (keeps the hot path cheap even under flood)
# -b : ring buffer (rotate at filesize kB, keep RING_FILES files)
exec /usr/bin/dumpcap \
  -i "$IFACE" -p \
  -s "$SNAPLEN" \
  -f "udp port ${PORT}" \
  -w "$OUTDIR/mohaa.pcapng" \
  -b filesize:"$RING_FILESIZE_KB" \
  -b files:"$RING_FILES"
