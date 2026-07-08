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

## Where the attack lands (largely resolved by live capture 2026-07-08)

The dispatcher (`SV_ConnectionlessPacket`) reads the command at **`data[5]`** — it skips the
4-byte `-1` marker **plus a 1-byte direction byte**. A **live inbound `getstatus` was
captured** and confirms the legit shape:

```
ff ff ff ff | 02 | 67 65 74 73 74 61 74 75 73     (14 bytes)
 -1 marker    dir  "getstatus"  (no newline)
```

So legit OOB = marker + **direction byte `0x02`** + command at `data[5]` → it reaches
`SVC_Status` and gets a 975-byte reply (~70× amplification, but the outbound bucket caps it
to ~10/s ≈ ~80 kbps → non-abusable).

The NFO-flagged (unverified) **attack** shape is different: `ff ff ff ff "getstatus" 0a` —
command at `data[4]`, **no** direction byte, trailing newline. Fed through the same parser
(which reads from `data[5]`) the token becomes **`etstatus`** → the **unknown/bad
connectionless branch**. So the attack:
- never reaches `SVC_Status`, never hits the per-IP O(16384) bucket scan, and sends no reply;
- costs only inbound CPU — `MSG_ReadStringLine` + `Cmd_TokenizeString` + the `Q_stricmp`
  chain — **unthrottled**, in the single-threaded server loop.

**Therefore a `SVC_Status`-only guard would miss the real attack.** The primary Phase 3 guard
belongs **early in `SV_ConnectionlessPacket` (before tokenize/dispatch)** so it protects the
game loop regardless of which command the flood (mis)parses to — see
`phase3-getstatus-shadow-guard.md`. This is an inference from the verified parser + the live
capture + the NFO signature; **Phase 2's `unknown` counter + `unk_sample` will confirm it
empirically during the next attack** (expect `unk_sample=etstatus`). A smarter attacker who
adds the `0x02` byte would instead show up under `getstatus` — Phase 2 sees both.

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
