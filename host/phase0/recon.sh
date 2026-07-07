#!/usr/bin/env bash
# MOHAAShield — Phase 0 recon (READ-ONLY).
# Gathers interface / driver / kernel / XDP-capability facts needed before we
# stand up the flight recorder or consider XDP. Changes nothing on the system.
#
# Usage:  sudo ./recon.sh [iface]
# If iface is omitted, the script guesses the default-route interface.
set -euo pipefail

IFACE="${1:-$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"

line() { printf '\n=== %s ===\n' "$1"; }

line "OS / kernel"
( . /etc/os-release 2>/dev/null && echo "distro: ${PRETTY_NAME:-unknown}" ) || true
echo "kernel: $(uname -r)"

line "Interfaces (brief)"
ip -brief address

if [ -z "${IFACE:-}" ]; then
  echo
  echo "Could not auto-detect the public interface. Re-run: sudo ./recon.sh <iface>"
  exit 0
fi
echo
echo "Selected interface: $IFACE"

line "Link details: $IFACE (look for an 'xdp' line = XDP already attached)"
ip -details link show dev "$IFACE" || true

line "Driver / firmware: $IFACE"
if command -v ethtool >/dev/null 2>&1; then
  ethtool -i "$IFACE" || true
  echo "-- ring parameters --"; ethtool -g "$IFACE" 2>/dev/null || echo "(ring info unavailable)"
  echo "-- channels/queues --"; ethtool -l "$IFACE" 2>/dev/null || echo "(channel info unavailable)"
else
  echo "ethtool not installed:  sudo apt install -y ethtool"
fi

line "XDP / eBPF tooling"
command -v bpftool >/dev/null 2>&1 && bpftool version || echo "bpftool not installed (later): sudo apt install -y bpftool"
echo "note: OVH KVM usually presents virtio_net -> expect GENERIC/SKB-mode XDP, not native."
echo "      Confirm later by attaching a tiny XDP program in native then generic mode."

line "Current RX/TX + drops on $IFACE (baseline snapshot)"
ip -s -s link show dev "$IFACE" | sed -n '1,8p' || true

line "Is anything already listening on UDP 12203?"
( ss -lunp 2>/dev/null | grep -E ':12203\b' || echo "nothing on 12203 (is the game server running here?)" )

cat <<'EOF'

=== NEXT (run manually, ~60s, still read-only) ===
Take one short sanity capture and eyeball the traffic shape:

  sudo tcpdump -ni <iface> -c 200 -tttt -e 'udp port 12203'

Look for:
  * payloads starting  ffffffff        -> connectionless (OOB) commands
  * "getstatus"/"getinfo"/"connect"    -> which OOB command
  * many distinct source IPs / churn   -> possible spoofing
  * clean incrementing per-source seq   -> real players (sequenced traffic)

Record the interface name + driver above; they parameterize the Phase 1 flight recorder.
EOF
