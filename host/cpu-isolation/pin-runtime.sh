#!/usr/bin/env bash
# MOHAAShield — runtime CPU isolation for the game (NO reboot). Pins omohaaded to its own core
# and pushes NIC interrupts + softirq packet-processing + the pcap recorder to the OTHER core.
# A flood the kernel is still receiving (before nftables drops it) then can't steal scheduling
# from the single-threaded game — which is the jitter cause when the game shares a core.
#
# Runtime only: nothing persists across reboot (undo = reboot). Make it permanent later with
# cpu-isolation/setup.sh (isolcpus, needs one reboot) + the mohaa.service CPUAffinity.
#   sudo bash host/cpu-isolation/pin-runtime.sh [--game-cpu 1] [--net-cpu 0] [--iface ens3]
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

GAME_CPU=1; NET_CPU=0; IFACE=""
while [ $# -gt 0 ]; do case "$1" in
  --game-cpu) GAME_CPU="${2:?}"; shift ;;
  --net-cpu)  NET_CPU="${2:?}";  shift ;;
  --iface)    IFACE="${2:?}";    shift ;;
  -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac; shift; done
: "${IFACE:=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')}"
NET_MASK=$(printf '%x' $(( 1 << NET_CPU )))

echo "== game -> CPU $GAME_CPU ,  network+capture -> CPU $NET_CPU  (iface $IFACE) =="

# 1) pin the game (all its threads) to its own core
PIDS="$(pgrep -x omohaaded || true)"
if [ -n "$PIDS" ]; then
  for p in $PIDS; do
    taskset -a -cp "$GAME_CPU" "$p" >/dev/null 2>&1 && echo "  pinned omohaaded pid $p -> CPU $GAME_CPU"
  done
else
  echo "  omohaaded not running (skipped game pin)"
fi

# 2) pin the pcap recorder (and any tshark) OFF the game core — it copies every flood packet
for p in $(pgrep -x dumpcap || true; pgrep -x tshark || true); do
  taskset -a -cp "$NET_CPU" "$p" >/dev/null 2>&1 && echo "  pinned capture pid $p -> CPU $NET_CPU"
done

# 3) steer NIC hardware IRQs to the network core
n=0
while read -r irq _; do
  irq="${irq%:}"; [ -w "/proc/irq/$irq/smp_affinity_list" ] || continue
  echo "$NET_CPU" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null && n=$((n+1))
done < <(grep -iE "${IFACE}|virtio[0-9].*(input|output)" /proc/interrupts)
echo "  steered $n NIC IRQ(s) -> CPU $NET_CPU"

# 4) steer software RPS (receive steering) off the game core
r=0
for q in /sys/class/net/"$IFACE"/queues/rx-*/rps_cpus; do
  [ -w "$q" ] || continue; echo "$NET_MASK" > "$q" 2>/dev/null && r=$((r+1))
done
echo "  set RPS on $r rx-queue(s) -> CPU $NET_CPU only"

echo
echo "done (runtime only — resets on reboot)."
echo "verify the game core is now quiet under flood:  sudo bash host/flood-snapshot.sh"
