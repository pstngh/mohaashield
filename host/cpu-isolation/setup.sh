#!/usr/bin/env bash
# MOHAAShield — reserve a CPU core for the game server (default CPU 1).
#
# Isolates the core so the scheduler, IRQs, timers and RCU stay on CPU 0, and ONLY an
# explicitly-pinned process (omohaaded via systemd CPUAffinity or `taskset -c N`) runs on it.
# Everything else (Linux, MOHAAShield, SSH, filtering) runs on CPU 0.
#
# Config only. Idempotent, backs up what it edits, requires ONE reboot. Does not touch how
# omohaaded is launched (the systemd unit's CPUAffinity, or a taskset wrapper, does the pin).
#   Override the core with:  CPU=1 sudo bash setup.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

CPU="${CPU:-1}"
NCPU="$(nproc)"
[ "$NCPU" -ge 2 ] || { echo "need >= 2 CPUs, found $NCPU"; exit 1; }
[ "$CPU" -ge 1 ] && [ "$CPU" -lt "$NCPU" ] || { echo "CPU must be 1..$((NCPU-1)), got $CPU"; exit 1; }

ISOL_PARAMS="isolcpus=${CPU} nohz_full=${CPU} rcu_nocbs=${CPU} irqaffinity=0"

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

# 2) systemd: default every managed process to CPU 0 (soft affinity, so a service's own
#    CPUAffinity=/taskset can still place omohaaded on the isolated core).
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/10-mohaashield-cpu.conf <<'EOF'
[Manager]
CPUAffinity=0
EOF
echo "wrote /etc/systemd/system.conf.d/10-mohaashield-cpu.conf (CPUAffinity=0)"

cat <<EOF

================================================================
Config written. NOT active yet — a reboot applies kernel isolation.

Make sure omohaaded is pinned to CPU ${CPU}:
  - systemd service: 'CPUAffinity=${CPU}' in the unit (install-mohaa-service.sh does this), or
  - screen/cron launch: prefix the binary with 'taskset -c ${CPU}'.

Then:  sudo reboot

After reboot, verify:
  cat /proc/cmdline                             # contains: isolcpus=${CPU} ...
  cat /sys/devices/system/cpu/isolated          # -> ${CPU}
  taskset -cp \$(pgrep -x omohaaded | head -1)   # -> ... current affinity list: ${CPU}
  ps -eo pid,psr,comm | awk '\$2==${CPU}'        # -> only omohaaded (+ idle per-CPU kthreads)

Rollback if boot ever fails (via OVH KVM console / rescue):
  restore /etc/default/grub.mohaashield.bak.*  then  update-grub  then reboot
================================================================
EOF
