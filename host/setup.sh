#!/usr/bin/env bash
# MOHAAShield — one-shot host setup for a Debian/Ubuntu game box.
#
# Installs the observability + hardening stack:
#   - flight recorder (bounded pcap ring on the game UDP ports) + auto-freeze watcher
#   - [--game-service]  omohaaded as a supervised systemd service pinned to a core
#   - [--cpu-isolation] reserve a core for the game (needs one reboot)
#
# Default (no component flags): recorder + watcher only (safe on any box).
# --all adds the game service and CPU isolation.
#
# Usage:
#   sudo bash host/setup.sh [--all] [--game-service] [--cpu-isolation]
#        [--iface IFACE] [--ports "12203 12300"]
#        [--game-user U] [--game-dir D] [--game-bin B] [--cpu N] [-y]
#
# Everything is idempotent and re-runnable. Config lands in /etc/mohaashield/.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0 ..."; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

# ---- defaults ----
DO_RECORDER=1; DO_GAME=0; DO_CPU=0; ASSUME_YES=0
IFACE=""; PORTS="12203 12300"
GAME_USER="${SUDO_USER:-debian}"; GAME_DIR=""; GAME_BIN="omohaaded"; CPU=1

usage(){ sed -n '2,20p' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --all)            DO_GAME=1; DO_CPU=1 ;;
    --recorder)       DO_RECORDER=1 ;;
    --game-service)   DO_GAME=1 ;;
    --cpu-isolation)  DO_CPU=1 ;;
    --iface)          IFACE="${2:?}"; shift ;;
    --ports)          PORTS="${2:?}"; shift ;;
    --game-user)      GAME_USER="${2:?}"; shift ;;
    --game-dir)       GAME_DIR="${2:?}"; shift ;;
    --game-bin)       GAME_BIN="${2:?}"; shift ;;
    --cpu)            CPU="${2:?}"; shift ;;
    -y|--yes)         ASSUME_YES=1 ;;
    -h|--help)        usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

: "${GAME_DIR:=/home/$GAME_USER/mohaa}"
: "${IFACE:=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')}"
[ -n "$IFACE" ] || { echo "could not auto-detect interface; pass --iface" >&2; exit 1; }

# ---- distro sanity ----
. /etc/os-release 2>/dev/null || true
case " ${ID:-} ${ID_LIKE:-} " in
  *debian*|*ubuntu*) : ;;
  *) echo "warning: not Debian/Ubuntu (${PRETTY_NAME:-unknown}); apt steps may fail" >&2 ;;
esac

echo "=== MOHAAShield setup ==="
printf '  interface     : %s\n' "$IFACE"
printf '  game ports    : %s\n' "$PORTS"
printf '  recorder      : %s\n' "$([ "$DO_RECORDER" = 1 ] && echo yes || echo no)"
printf '  game service  : %s\n' "$([ "$DO_GAME" = 1 ] && echo "yes ($GAME_USER  $GAME_DIR/$GAME_BIN  CPU $CPU)" || echo no)"
printf '  cpu isolation : %s\n' "$([ "$DO_CPU" = 1 ] && echo "yes (reserve CPU $CPU, needs reboot)" || echo no)"
if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Proceed? [y/N] " a; case "$a" in y|Y) ;; *) echo aborted; exit 1 ;; esac
fi

# ---- dependencies ----
echo "==> dependencies"
export DEBIAN_FRONTEND=noninteractive
echo 'wireshark-common wireshark-common/install-setuid boolean false' | debconf-set-selections 2>/dev/null || true
apt-get update -qq
apt-get install -y -qq tcpdump tshark ethtool conntrack nftables git >/dev/null
echo "    tcpdump tshark ethtool conntrack nftables git"

# ---- flight recorder + watcher ----
if [ "$DO_RECORDER" = 1 ]; then
  echo "==> flight recorder + attack-watch"
  mkdir -p /etc/mohaashield
  if [ ! -f /etc/mohaashield/flightrecorder.conf ]; then
    cat > /etc/mohaashield/flightrecorder.conf <<EOF
IFACE=$IFACE
PORTS="$PORTS"
SNAPLEN=128
OUTDIR=/var/lib/mohaashield/pcap
RING_FILESIZE_KB=32768
RING_FILES=64
FREEZE_FILES=8
MAX_INCIDENTS=5
WATCH_INTERVAL=2
WATCH_PPS_TRIGGER=4000
WATCH_DROP_TRIGGER=1
WATCH_REARM_QUIET=60
WATCH_MAX_HOLD=1800
EOF
    echo "    wrote /etc/mohaashield/flightrecorder.conf (IFACE=$IFACE PORTS=\"$PORTS\")"
  else
    echo "    kept existing /etc/mohaashield/flightrecorder.conf (check IFACE/PORTS)"
  fi
  bash "$SRC/phase1/install.sh" >/dev/null
  systemctl enable --now mohaashield-flightrecorder mohaashield-attack-watch
  echo "    services enabled: mohaashield-flightrecorder, mohaashield-attack-watch"
fi

# ---- game systemd service ----
if [ "$DO_GAME" = 1 ]; then
  echo "==> systemd game service"
  if [ -x "$GAME_DIR/$GAME_BIN" ]; then
    GAME_USER="$GAME_USER" GAME_DIR="$GAME_DIR" GAME_BIN="$GAME_BIN" CPU="$CPU" \
      bash "$SRC/systemd/install-mohaa-service.sh"
  else
    echo "    SKIPPED: $GAME_DIR/$GAME_BIN not found (install the game first, then re-run with"
    echo "             --game-service, or: sudo GAME_DIR=$GAME_DIR bash $SRC/systemd/install-mohaa-service.sh)"
  fi
fi

# ---- CPU isolation ----
NEED_REBOOT=0
if [ "$DO_CPU" = 1 ]; then
  echo "==> CPU isolation (reserve CPU $CPU)"
  CPU="$CPU" bash "$SRC/cpu-isolation/setup.sh"
  NEED_REBOOT=1
fi

echo
echo "=== done ==="
[ "$DO_RECORDER" = 1 ] && echo "  recorder: systemctl status mohaashield-flightrecorder mohaashield-attack-watch"
[ "$DO_GAME" = 1 ] && [ -x "$GAME_DIR/$GAME_BIN" ] && echo "  game:     systemctl status mohaa"
if [ "$NEED_REBOOT" = 1 ]; then
  echo "  ACTION:   reboot to apply CPU isolation ->  sudo reboot"
fi
echo "  firewall/conntrack are a separate, deliberate step (see docs/host-environment.md +"
echo "  host/nftables/add-notrack.sh) — not auto-applied here to avoid remote lockout."
