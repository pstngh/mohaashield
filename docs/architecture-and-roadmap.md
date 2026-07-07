# MOHAAShield architecture & roadmap

A highly specialized, protocol-aware protection system for **one** game server
(OpenMoHAA, UDP 12203) — not a general anti-DDoS network. The design edge over generic
products (EvoShield L2, etc.) is that MOHAAShield can see MOHAA protocol state by
patching the engine itself.

## Layered architecture

| Layer | Role | Owner |
|---|---|---|
| **1. OVH VAC / Edge firewall** | Volumetric floods, reflection/amplification, anything above the 500 Mbps uplink, broad L3/L4. Stateless — does NOT understand MOHAA payloads. | Provider |
| **2. XDP/eBPF fast path** | Cheap early drop of known-impossible/known-attack packets, dynamic source/prefix blocks, lightweight counters. Focus on UDP 12203 only. | MOHAAShield (later) |
| **3. OpenMoHAA source-level protocol firewall** | The strongest layer. Uses the engine's parser, challenge/client state, and leaky-bucket primitive to classify and rate-limit connectionless commands with full protocol context. | MOHAAShield |
| **4. Userspace control & telemetry** | Read counters, compute rates, toggle attack mode, add/expire dynamic blocks, trigger capture, summarize incidents. | MOHAAShield (later) |

### Assessment (why this order)
- The biggest **near-term** win is a small Layer-3 change + telemetry, **not** XDP. XDP
  earns its keep only once the attack is characterized and we need to shed load before
  userspace.
- **XDP reality on this VPS:** OVH KVM presents `virtio_net`; expect **generic/SKB-mode
  XDP**, not native. Still useful (drops before the UDP socket and before OpenMoHAA) but not
  a line-rate hardware bypass. *Verify on the real box* — don't assume.
- The **volumetric ceiling stays OVH's job** (500 Mbps uplink). MOHAAShield handles what
  survives upstream because it looks like legitimate MOHAA traffic.

## Roadmap

**v1 (this milestone) — observe-only, zero drops:**
- **Phase 0 — Baseline & visibility** *(host, read-only)*: confirm OS/iface/driver/kernel +
  XDP capability; install capture tooling; one sanity capture. → `host/phase0/`
- **Phase 1 — 24/7 flight recorder** *(host)*: bounded `dumpcap` ring on UDP 12203,
  hardened systemd service, manual incident `freeze`. → `host/phase1/`
- **Phase 2 — Connectionless telemetry** *(engine patch)*: aggregated per-command
  counters + once-per-window print. Learns the real legit OOB baseline. No drops.
- **Phase 3 — Shadow-mode getstatus guard** *(engine patch)*: global inbound getstatus
  leaky bucket *before* the per-IP scan + non-dropping bucket-allocator cursor fix. Counts
  "would-drop"; drops nothing. Cvars: `sv_shieldGetstatus` (0 off / 1 shadow / 2 enforce,
  default 1) + live-tunable burst/period.

**Later (scoped, deferred):**
- **Phase 4** — enable getstatus mitigation after validating thresholds against real data.
- **Phase 5** — automatic PCAP analyzer + capture triggers.
- **Phase 6** — XDP/eBPF fast-path classification.
- **Phase 7** — dynamic cooperation between OpenMoHAA and BPF maps.
- **Phase 8** — protocol-state-aware protection for additional vectors (connect throttle,
  disconnect-reflection guard, etc.).

## Performance targets (engineering goals, to be benchmarked)

- Normal state: unnoticeable latency, low single-digit % CPU, < ~256 MB RAM, bounded
  logs/PCAP.
- Under attack: MOHAAShield may burn CPU if it keeps MOHAA and the kernel stack alive.

## Default decisions (recommended; override any with one word)

1. **First deploy = current production box now** (capture real attacks before the OVH
   migration; if it isn't Debian, tell me its OS and Phase 0 tooling adjusts). Re-run on OVH
   after migration.
2. **Build model = self-compiled `omohaaded`** from source, shipped as small patches + a
   build script pinned to a known-good upstream commit (required for Layer 3).
3. **v1 extras = bucket-allocator cursor fix only.** OVH Edge firewall allowlist and OS
   sysctls are an optional "Phase 0.5", not core v1.
