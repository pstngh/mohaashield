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
  setup.sh                       one-shot orchestrator (deps + recorder + optional game svc / CPU isolation)
  phase0/recon.sh                READ-ONLY: iface/driver/kernel/XDP capability + sanity capture
  phase1/                        24/7 dumpcap flight recorder + auto-freeze watcher (hardened systemd)
  systemd/                       run omohaaded as a supervised service pinned to a core
  cpu-isolation/                 reserve a core for the game (isolcpus + systemd affinity)
  nftables/                      conntrack-bypass helper for the game ports
```

## Set up a new Debian/Ubuntu box (one command)

```bash
sudo apt install -y git && git clone -b claude/mohaashield-ddos-protection-87p5ne \
  https://github.com/pstngh/mohaashield.git && cd mohaashield

# recorder + watcher only (safe on any box):
sudo bash host/setup.sh

# or the full game-box stack (adds systemd game service + CPU isolation):
sudo bash host/setup.sh --all --game-user debian --game-dir /home/debian/mohaa
```

`setup.sh` auto-detects the interface, installs deps, writes `/etc/mohaashield/`, and enables
the services. `--all` also installs the `mohaa.service` (pinned to CPU 1) and CPU isolation
(**one reboot** applies it). Flags: `--iface`, `--ports`, `--game-user/-dir/-bin`, `--cpu`, `-y`.
Re-runnable and idempotent. Options without `--all` install just the recorder.

The firewall/conntrack pieces are intentionally **not** auto-applied (a policy-drop ruleset can
lock you out of a remote box) — apply those deliberately (`host/nftables/add-notrack.sh`,
`docs/host-environment.md`). First-time recon is still available read-only:
`sudo bash host/phase0/recon.sh`. After an attack: `sudo /opt/mohaashield/freeze.sh <tag>`.

## Engine work (Phase 2 / 3)

Layer-3 changes ship as **anchor-based implementation specs** in `patches/` (the operator
runs a self-compiled, customized `omohaaded` fork). Start with `patches/README.md`:
- `patches/phase2-telemetry.md` — aggregated connectionless telemetry (observe-only).
- `patches/phase3-getstatus-shadow-guard.md` — shadow getstatus gate + allocator fix (zero
  drops by default), applied after Phase 2 data review.

## The getstatus signature (unverified NFO-era prior)

An NFO mitigation alert on the *old* host flagged `FF FF FF FF "getstatus" \n` (14-byte
connectionless payload) as a "getstatus flood." That is a second-hand, automated
classification from behind NFO's scrubbing — **not independently verified as an attack**, and
the same byte shape is also sent by legitimate server-list crawlers. This OVH box sits behind
different upstream mitigation (VAC), so the real vector must be established from captures on
*this* box. Treated as a hypothesis, not a fact. See `docs/threat-model.md`.
