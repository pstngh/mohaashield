# MOHAAShield engine patches (implementation specs)

These are **implementation specifications**, not upstream diffs. Your OpenMoHAA fork is
customized, so applying a line-based patch would be fragile. Instead, each spec describes
*what* to change, anchored by **function name + nearby code landmarks**, so the session that
maintains your fork can implement it correctly against your actual source.

## Order & safety

1. **`phase2-telemetry.md`** — do this first. Pure observation: aggregated counters + one
   print per window. **Drops nothing, changes no response.** This gives us the real baseline
   and tells us which vector current attacks actually use.
2. **`phase3-getstatus-shadow-guard.md`** — do this after Phase 2 is running and you've seen
   a few windows. Adds a cheap global getstatus gate (default **shadow** — still zero drops)
   plus a non-dropping allocator hardening.

**Invariants both specs must preserve (non-negotiable):**
- Connected players (sequenced / netchan-authenticated traffic) are **never** touched. A
  false player disconnect is a build-failing bug.
- No per-packet logging. Only one aggregated print per window (default 5 s), and only when
  there was activity.
- Everything defaults to observe/shadow. Enforcement is a separate cvar flip, done only
  after data review.
- Bounded memory only. No new unbounded maps/queues.

## Important open question the telemetry will resolve

The dispatcher (`SV_ConnectionlessPacket`) reads the command at **`data[5]`** — it skips the
4-byte `-1` marker **plus a 1-byte direction byte**. A legit MOHAA `getstatus` therefore
looks like `FF FF FF FF <dir> "getstatus\n"` (command at `data[5]`). But the confirmed
historical attack was **14 bytes**: `FF FF FF FF "getstatus\n"` — command at `data[4]`, **no
direction byte**. Parsed by this dispatcher, that packet's command token becomes `"etstatus"`
→ the **unknown/bad** branch, *not* `SVC_Status`.

Consequences we must not guess about:
- If the flood really parses as **unknown**, it never reaches the per-IP bucket scan, and a
  `SVC_Status`-only guard would miss it.
- If your attacker's tool includes the direction byte, it parses as **getstatus** and does
  hit the scan.

Phase 2 counts **both** `getstatus` and `unknown`, and **samples the unknown command token**,
so a single attack window tells us exactly which path the flood takes — and therefore where
Phase 3/4 mitigation must sit. (If your fork customized OOB header handling, verify the
`data[5]` offset in your `SV_ConnectionlessPacket` before implementing.)

## Paste-ready handoff prompt

> You maintain my customized OpenMoHAA dedicated-server fork (`omohaaded`). Implement the
> **MOHAAShield Phase 2 telemetry** patch exactly as specified in
> `patches/phase2-telemetry.md` from the MOHAAShield repo (contents pasted below / attached).
> Hard constraints: observe-only, **zero packet drops**, no per-packet logging, exactly one
> aggregated `Com_Printf` per window, and connected players must be provably unaffected.
> Match the anchor points by **function name and nearby calls** — my source may differ from
> upstream line numbers; if an anchor looks different in my fork, stop and show me the
> relevant function before editing. First verify the `data[5]` command offset noted in the
> spec against my `SV_ConnectionlessPacket`. After implementing, build with my normal server
> build and run the verification recipe at the end of the spec, then show me a sample of the
> window print. Do **not** implement Phase 3 yet.

Then, after a few Phase 2 windows (ideally including one real attack), hand over
`phase3-getstatus-shadow-guard.md` the same way.
