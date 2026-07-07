#!/usr/bin/env bash
# MOHAAShield — install the Phase 1 flight recorder as a hardened systemd service.
# Run as root on the game-server host (Debian 13 assumed).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./install.sh"; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"

echo "==> dependencies (dumpcap)"
if ! command -v dumpcap >/dev/null 2>&1; then
  apt update && apt install -y tshark   # provides /usr/bin/dumpcap
fi

echo "==> system user 'mohaashield'"
if ! id -u mohaashield >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin mohaashield
fi

echo "==> directories"
install -d -o mohaashield -g mohaashield -m 0750 /var/lib/mohaashield/pcap
install -d -o mohaashield -g mohaashield -m 0750 /var/lib/mohaashield/incidents
install -d -m 0755 /opt/mohaashield /etc/mohaashield

echo "==> files"
install -m 0755 "$SRC/flightrecorder-run.sh" /opt/mohaashield/flightrecorder-run.sh
install -m 0755 "$SRC/freeze.sh"             /opt/mohaashield/freeze.sh
if [ ! -f /etc/mohaashield/flightrecorder.conf ]; then
  install -m 0644 "$SRC/flightrecorder.conf.example" /etc/mohaashield/flightrecorder.conf
  echo "    created /etc/mohaashield/flightrecorder.conf  (EDIT: set IFACE)"
else
  echo "    kept existing /etc/mohaashield/flightrecorder.conf"
fi
install -m 0644 "$SRC/mohaashield-flightrecorder.service" /etc/systemd/system/mohaashield-flightrecorder.service

systemctl daemon-reload
cat <<EOF

Installed. Next:
  1) Edit /etc/mohaashield/flightrecorder.conf  -> set IFACE (from Phase 0 recon)
  2) sudo systemctl enable --now mohaashield-flightrecorder
  3) systemctl status mohaashield-flightrecorder
  4) ls -lh /var/lib/mohaashield/pcap   (ring files should appear/rotate)

During/after an attack, preserve the window:
  sudo /opt/mohaashield/freeze.sh <tag>
EOF
