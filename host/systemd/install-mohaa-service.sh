#!/usr/bin/env bash
# MOHAAShield — run omohaaded as a supervised systemd service on CPU 1.
#
# Replaces the cron + screen + gs.sh launcher with a proper unit:
#   - auto-restarts on crash forever, ~2s apart (like the old `while true` loop)
#   - pinned to CPU 1 via CPUAffinity (no taskset/screen)
#   - safe logging args baked in (developer 0, logfile 1) to kill the per-packet log DoS
#   - logs to journald:  journalctl -u mohaa -f
# It writes the unit, enables it for boot, and DISABLES the old @reboot cron line so the
# two launchers can't both start the server. It does NOT start it now (avoids a port clash
# with the currently-running instance) — the switch happens at your reboot. Idempotent.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

GAME_USER="${GAME_USER:-debian}"
GAME_DIR="${GAME_DIR:-/home/debian/mohaa}"
GAME_BIN="${GAME_BIN:-omohaaded}"
GAME_ARGS="${GAME_ARGS:-+set com_target_game 0 +set net_port 12203 +set developer 0 +set logfile 1 +set net_queryport 12300 +exec server_opm.cfg}"
CPU="${CPU:-1}"

[ -x "$GAME_DIR/$GAME_BIN" ] || { echo "not found/executable: $GAME_DIR/$GAME_BIN (set GAME_DIR/GAME_BIN)"; exit 1; }

echo "==> writing /etc/systemd/system/mohaa.service"
cat > /etc/systemd/system/mohaa.service <<EOF
[Unit]
Description=OpenMoHAA dedicated server
After=network-online.target
Wants=network-online.target
# never stop retrying after crashes (matches the old gs.sh loop)
StartLimitIntervalSec=0

[Service]
Type=simple
User=$GAME_USER
WorkingDirectory=$GAME_DIR
ExecStart=$GAME_DIR/$GAME_BIN $GAME_ARGS
Restart=always
RestartSec=2
# dedicate CPU $CPU to the game (works with isolcpus=$CPU)
CPUAffinity=$CPU

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mohaa    # start at boot; NOT --now (avoid clashing with the running instance)

echo "==> disabling the old @reboot cron launcher for '$GAME_USER'"
if crontab -u "$GAME_USER" -l 2>/dev/null | grep -q '^@reboot .*gs\.sh'; then
  crontab -u "$GAME_USER" -l > "/root/crontab.${GAME_USER}.mohaashield.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  crontab -u "$GAME_USER" -l | sed 's|^@reboot .*gs\.sh.*|# &  # disabled by MOHAAShield (replaced by mohaa.service)|' | crontab -u "$GAME_USER" -
  echo "    commented out the @reboot gs.sh line (backup in /root/)"
else
  echo "    no active @reboot gs.sh line found (already disabled?)"
fi

cat <<EOF

Done. The service is enabled for boot but not started (your current screen instance keeps
running until you reboot). Recommended: reboot to switch over cleanly.

  cd ~/mohaashield && git pull --ff-only
  sudo bash host/cpu-isolation/setup.sh
  sudo reboot

After reboot, verify:
  systemctl status mohaa --no-pager
  taskset -cp "\$(pgrep -x $GAME_BIN | head -1)"   # affinity list: $CPU
  ps -eo pid,psr,comm | awk '\$2==$CPU'            # only $GAME_BIN on CPU $CPU
  ps -C $GAME_BIN -o args=                         # developer 0 / logfile 1
  journalctl -u mohaa -n 20 --no-pager

To switch over NOW instead of waiting (drops players briefly):
  sudo -u $GAME_USER screen -S forte -X quit 2>/dev/null || true
  sudo pkill -u $GAME_USER -f '$GAME_DIR/gs.sh' 2>/dev/null || true
  sudo pkill -x $GAME_BIN 2>/dev/null || true
  sleep 2 && sudo systemctl start mohaa && systemctl status mohaa --no-pager

The old gs.sh / gsload.sh are now unused (safe to leave or delete later).
EOF
