# Incident 2026-07-08 — `connect` flood (CONFIRMED, first real capture)

First attack captured on the OVH box by the MOHAAShield flight recorder. **This confirms the
attack vector empirically** (previously only a source-code hypothesis).

## When
Near-continuous auto-freeze triggers ~08:42–12:05 UTC (multiple episodes), rx_pps bursting to
~62,000 (attack-watch log). Subsided by ~12:xx (`vmstat` steal=0, box ~88% idle).

## What it is — a connectionless `connect` flood
From a preserved 32 MB slice (`incidents/20260708T120449Z_auto`, 66.85 s):
- **85% of packets are connectionless (OOB, `ffffffff`-prefixed)** — not volumetric/sequenced.
- Inbound OOB command breakdown (117,618 inbound OOB packets):
  | command | count | note |
  |---|---|---|
  | **connect** | **88,230 (75%)** | the un-throttled `SV_DirectConnect` path |
  | rcon | 5,996 | rate-limited |
  | getstatus | 5,942 | rate-limited |
  | getinfo | 5,890 | rate-limited |
  | getchallenge | 5,750 | rate-limited |
  | disconnect | 0 | |
- The rate-limited commands are all capped ~5,900; only `connect` runs away — **proof the
  missing rate limit on `connect` is what's being exploited.**

## Sources — few, real, bannable
- **Only 17 unique source IPs** — NOT a massively-spoofed flood.
- **Dominant: `41.44.154.180`** (Egypt / TE Data), flooding from many *ephemeral* source ports
  (59214, 64184, 63488…) — ~40% of all frames; the server was replying to it at ~436 pps.
  Ephemeral ports that vary while the IP stays fixed ⇒ a **real host**, not spoofed ⇒ bannable.
- ~12 other sources use **source port 12203** (real clients never do) ⇒ likely spoofed or
  reflection; do **not** ban these individually (could be innocent spoofed victims).

## Impact
Server **coped** — omohaaded ~15% CPU on its isolated core, RAM fine, OVH steal=0. The CPU
isolation + notrack + `developer 0/logfile 1` fix absorbed it. Costs were wasted CPU (2048-scan
per packet) and ~436 pps of outbound "bad challenge" reflection.

## Mitigation
1. **Interim:** ban the ephemeral-port flooder(s) (e.g. `41.44.154.180`) via nftables
   `dynamic_bans_v4` (timed — the IP is likely dynamic). Whack-a-mole if they rotate IPs.
2. **Durable (the real fix):** **rate-limit the `connect` path in the engine.** A global OOB
   gate at the top of `SV_ConnectionlessPacket` (Phase 3, design 3a′) caps `connect` for ANY
   source, spoofed or not — which banning cannot. Now fully data-justified. Phase 2 telemetry
   first to measure the legit `connect` rate and set the threshold so real joins pass.
