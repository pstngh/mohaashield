# MOHAAShield threat model

Classifies the attack surface of an OpenMoHAA server on UDP 12203, separating **confirmed
facts** from **hypotheses that need a PCAP/profile** — because we only build mitigation on
facts. See `openmohaa-source-analysis.md` for the code behind each claim.

## Confirmed source-code concerns (mechanism proven in code)

1. **Algorithmic-complexity DoS in `SVC_BucketForAddress`.** Every new/spoofed source IP
   triggers an **O(16384) scan from index 0**, run *before* the cheap global outbound gate.
   Affects `getstatus`/`getinfo`/`getchallenge`/`rcon`. **Directly matches the confirmed
   historical `getstatus` flood** (`FF FF FF FF "getstatus" \n`, 14-byte payload).
2. **`connect` is un-throttled and is the heaviest pre-auth path** (Huffman decode +
   userinfo parsing + 2048-entry challenge scan). The likely pivot target once `getstatus`
   is gated.
3. **Sequenced-unknown-source → OOB `disconnect` reflection**, un-throttled. Low
   amplification but lets the box be used as a weak reflector and forces outbound PPS/CPU.

## Already well-defended — do NOT "fix" these

- **Outbound amplification** — capped at ~10 status/info/challenge replies/sec globally.
- **Memory exhaustion** — none of these paths allocate unbounded state (fixed arrays).
- **Injection into live players** — netchan challenge-checksum gate.

## Minor / defense-in-depth

- Weak challenge PRNG (`((rand()<<16)^rand())^svs.time`) — only exploitable by an attacker
  who can also observe/guess the challenge delivered to the target IP.
- No dispatcher-level OOB length guard (handler-level `>128` guards exist).
- Per-packet `Cvar_VariableValue("g_gametype")` string lookup in `SVC_Status` before the limiter.

## Hypotheses needing a PCAP/profile (not yet proven — this is why we observe first)

- The **actual CPU cost** per vector on the 2-vCPU target box.
- **Which vector the current (non-getstatus-alerting) attacks use** — could be a connect
  flood, getinfo, mixed OOB, or spoofed sequenced traffic. If Phase-2 telemetry shows the
  pressure is on sequenced traffic or is purely volumetric, the mitigation plan pivots.

## Safety invariants (hold for ALL MOHAAShield work)

1. **Connected players are never touched.** All new logic sits only on connectionless OOB
   commands; the sequenced/netchan-authenticated path is untouched. A false player
   disconnect is a build-failing bug.
2. **Default = shadow/observe.** Every drop is opt-in via cvar, enabled only after real data
   justifies the threshold.
3. Every mitigation has a **cvar kill-switch**, **bounded memory**, and — for any dynamic
   block — **automatic expiry**.
4. **No per-packet logging** on any hot path. Aggregate counters; print at most once per
   window; keep verbose paths on `Com_DPrintf` (developer-gated). Logging must never become
   a DoS vector.
5. A small **allowlist** for known-good monitors (your uptime checker, community browsers)
   so legitimate observers are never throttled.

## Thresholds & assumptions (no invented limits)

- **Global getstatus gate:** legit getstatus = periodic server-browser/master-list/monitor
  queries — low aggregate rate; the 82 ms normal capture saw **zero** OOB traffic, so we
  lack a real number. **Measure the aggregate legit rate over days in Phase 2, then set the
  enforce threshold to ~5–10× the observed peak.** A *starting shadow* value to validate
  (not a final constant): burst ~100, period ~10 ms (≈100/sec). Floods are 10k–250k/sec —
  2–3 orders of magnitude above legit — so the separation is wide. The gate is **global**:
  when it trips it also drops legit status queries (a browser can't see the server
  mid-attack). **Acceptable** — status visibility degrades, gameplay does not, and existing
  players (sequenced) are unaffected.
- **Existing per-IP limiter (unchanged):** 1/sec sustained, burst 10 — already strict; we
  keep it and avoid *reaching* it via the cheaper global gate under flood.
- **Connect throttle (later, measured):** a legit client connects ~once per join; ≤64
  players; joins are spread out → a small global connect budget is generous. Measure first.
