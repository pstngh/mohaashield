#!/usr/bin/env bash
# MOHAAShield — reserve CPU 1 for the game server.
#
# Isolates CPU 1 so the scheduler, IRQs, timers and RCU stay on CPU 0, and ONLY an
# explicitly-pinned process (omohaaded via `taskset -c 1`) runs on CPU 1. Everything else
# (Linux, MOHAAShield, SSH, filtering) runs on CPU 0.
#
# This writes config only. It is idempotent, backs up what it edits, and requires ONE
# reboot to take effect. It does NOT touch your crontab — you add `taskset -c 1` to the
# omohaaded launch yourself (see the printed instructions).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

NCPU="$(nproc)"
[ "$NCPU" -ge 2 ] || { echo "need >= 2 CPUs, found $NCPU"; exit 1; }

ISOL_PARAMS="isolcpus=1 nohz_full=1 rcu_nocbs=1 irqaffinity=0"

echo "current cmdline: $(cat /proc/cmdline)"

# 1) Kernel cmdline via GRUB.
GRUB=/etc/default/grub
if [ ! -f "$GRUB" ]; then
  echo "WARNING: $GRUB not found — this box may not use GRUB. Stop and check the bootloader" >&2
  echo "         before continuing; do NOT reboot until '$ISOL_PARAMS' is in /proc/cmdline." >&2
  exit 1
fi
if grep -q 'isolcpus=' "$GRUB"; then
  echo "grub already contains isolcpus= — leaving $GRUB unchanged"
else
  cp -a "$GRUB" "${GRUB}.mohaashield.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB"; then
    sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 ${ISOL_PARAMS}\"/" "$GRUB"
  elif grep -q '^GRUB_CMDLINE_LINUX=' "$GRUB"; then
    sed -i "s/^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"/\1 ${ISOL_PARAMS}\"/" "$GRUB"
  else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${ISOL_PARAMS}\"" >> "$GRUB"
  fi
  echo "added to GRUB cmdline: ${ISOL_PARAMS}"
fi
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg

# 2) systemd: default every managed process to CPU 0 (soft affinity, so taskset can still
#    place omohaaded on CPU 1). isolcpus already keeps the scheduler off CPU 1; this is
#    belt-and-suspenders and makes intent explicit.
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/10-mohaashield-cpu.conf <<'EOF'
[Manager]
CPUAffinity=0
EOF
echo "wrote /etc/systemd/system.conf.d/10-mohaashield-cpu.conf (CPUAffinity=0)"

cat <<EOF

================================================================
Config written. NOT active yet — a reboot applies kernel isolation.

BEFORE you reboot, pin omohaaded to CPU 1 in your cron/screen launch by inserting
'taskset -c 1' immediately before the omohaaded binary, e.g.:

  screen -dmS mohaa taskset -c 1 /path/to/omohaaded +set com_target_game 0 +exec server_opm.cfg

(If a watchdog script does the launch, put 'taskset -c 1' before omohaaded there.)

Then:  sudo reboot

After reboot, verify:
  cat /proc/cmdline                             # contains: isolcpus=1 ...
  cat /sys/devices/system/cpu/isolated          # -> 1
  taskset -cp \$(pgrep -x omohaaded | head -1)   # -> ... current affinity list: 1
  ps -eo pid,psr,comm | awk '\$2==1'             # -> only omohaaded shows CPU 1

Rollback if boot ever fails (via OVH KVM console / rescue):
  restore /etc/default/grub.mohaashield.bak.*  then  update-grub  then reboot
================================================================
EOF
