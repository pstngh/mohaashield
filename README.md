# MOHAAShield

Protocol-aware DDoS/DoS protection for a single **OpenMoHAA** (Medal of Honor: Allied
Assault) game server on **UDP 12203**. Not a general anti-DDoS network — a specialized
system that beats generic scrubbers *for this one protocol* by reading MOHAA protocol
state directly in the engine.

> **Status:** v1 in progress — **observe-only, drops nothing.** We gather real attack data
> first, then build targeted mitigation. A false-positive player disconnect is treated as a
> build-failing bug; a false-positive capture is fine.

## Layers

1. **OVH VAC / Edge firewall** — volumetric floods, reflection, anything above the uplink (provider).
2. **XDP/eBPF fast path** — cheap early drops + counters (later phase).
3. **OpenMoHAA source-level protocol firewall** — the strongest layer; uses the engine's
   parser, challenge/client state, and leaky-bucket primitive.
4. **Userspace control & telemetry** — rates, attack-mode, dynamic blocks, capture (later phase).

## Layout

```
docs/
  architecture-and-roadmap.md    layers, assessment, phased roadmap, decisions
  openmohaa-source-analysis.md   verified engine internals (rate limiter, dispatch, thresholds)
  threat-model.md                classified surfaces, safety invariants, threshold reasoning
host/
  phase0/recon.sh                READ-ONLY: iface/driver/kernel/XDP capability + sanity capture
  phase1/                        24/7 dumpcap flight recorder (bounded ring, hardened systemd)
```

## Quick start (Phase 0 — read-only, changes nothing)

```bash
sudo apt update && sudo apt install -y tcpdump tshark ethtool
sudo bash host/phase0/recon.sh            # note the interface name + driver it reports
```

Then stand up the always-on flight recorder (Phase 1):

```bash
sudo bash host/phase1/install.sh
sudo nano /etc/mohaashield/flightrecorder.conf     # set IFACE from Phase 0
sudo systemctl enable --now mohaashield-flightrecorder
# after an attack:  sudo /opt/mohaashield/freeze.sh <tag>
```

## What's next

Phase 2 (engine telemetry) and Phase 3 (shadow-mode getstatus guard) are OpenMoHAA source
patches — deferred until the build/deploy model is confirmed. See
`docs/architecture-and-roadmap.md`.

## Confirmed historical attack

`FF FF FF FF "getstatus" \n` (14-byte connectionless payload). Newer attacks may use other
vectors — hence observe-first. See `docs/threat-model.md`.
