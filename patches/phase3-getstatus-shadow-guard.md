# Phase 3 — Shadow-mode OOB flood guard + allocator hardening

> **DESIGN UPDATE (live capture 2026-07-08).** A real `getstatus` was captured and confirms
> legit OOB carries a direction byte (`ff ff ff ff 02 "getstatus"`, command at `data[5]`).
> The NFO-flagged **attack** shape (`ff ff ff ff "getstatus" 0a`, command at `data[4]`; still
> unverified on this box) misparses to the **unknown/bad connectionless branch** — so it never
> reaches `SVC_Status`. A
> `SVC_Status`-only gate (3a below) would therefore **miss the real attack**. The recommended
> primary guard is now **(3a′) a global OOB gate at the top of `SV_ConnectionlessPacket`,
> before tokenize/dispatch** — it protects the single-threaded server loop against *any*
> connectionless flood (getstatus, misparsed `etstatus`, getinfo, connect) with one cheap
> check, and never touches sequenced player traffic (that path is handled earlier in
> `SV_PacketEvent`). Keep 3a as a narrower add-on if you want per-command shaping. **Wait for
> Phase 2 data to set the threshold and confirm the attack shape (`unk_sample=etstatus`) before
> implementing.**

**Do this only after Phase 2 is running** and you've seen a few windows (ideally one real
attack), so the Phase-2 data tells us whether the flood arrives as `getstatus` or `unknown`,
and what the legit *aggregate* OOB rate is.

## 3a′ — global OOB gate at the top of the dispatcher (recommended primary)

Place a single cheap leaky-bucket check at the **start of `SV_ConnectionlessPacket`**, right
after the `MSG_ReadLong`/`MSG_ReadByte` header skips and **before** `MSG_ReadStringLine` +
`Cmd_TokenizeString` (the expensive part). Cvars `sv_shieldOOB` (0 off / 1 shadow / 2 enforce,
default 1) + `sv_shieldOOBBurst` / `sv_shieldOOBPeriodMs`.

```c
    /* after: MSG_ReadLong(msg); MSG_ReadByte(msg);  — before MSG_ReadStringLine/Cmd_Tokenize */
    if ( sv_shieldOOB && sv_shieldOOB->integer ) {
        static leakyBucket_t oobInboundBucket;
        int burst  = sv_shieldOOBBurst->integer;
        int period = sv_shieldOOBPeriodMs->integer;
        if ( period < 1 ) period = 1;          /* SVC_RateLimit divides by period */
        if ( burst  < 1 ) burst  = 1;
        if ( burst  > 127 ) burst = 127;       /* leakyBucket_t.burst is signed char */
        if ( SVC_RateLimit( &oobInboundBucket, burst, period ) ) {
            if ( sv_shieldOOB->integer >= 2 ) { /* ENFORCE: drop before the expensive tokenize */
                sh_stats.oob_gate_drop++;
                return;
            } else {                            /* SHADOW: count, then proceed as stock */
                sh_stats.oob_gate_would_drop++;
            }
        }
    }
```

Add `oob_gate_drop` / `oob_gate_would_drop` to the Phase 2 `sh_stats` struct. Threshold: set
`burst`/`period` from the Phase-2 **aggregate** legit OOB peak (getstatus+getinfo+getchallenge
+connect combined, which spikes during join bursts), then ~5–10×. In enforce mode this drops
*all* OOB during a flood — status queries and new joins fail, **but connected players are
untouched** (sequenced path). This is the invariant-safe, highest-CPU-relief placement.

The `SVC_Status`-specific gate below (3a) remains valid as a *narrower* control if you prefer
to only shape true `getstatus`; it does not, by itself, stop the misparsed-`etstatus` attack.

---

Two changes, both **non-dropping by default**:
- **(3a) Global inbound getstatus gate** — a single cheap leaky bucket checked *before* the
  per-IP bucket scan in `SVC_Status`. Default mode is **shadow**: it only counts what it
  *would* drop. Its purpose when later enforced is to short-circuit the O(16384) per-IP scan
  during a flood.
- **(3b) Rotating allocator cursor** — makes `SVC_BucketForAddress` start its free-slot scan
  from a rotating index instead of always index 0. Changes allocation *order* only; **never
  drops a packet**. Safe to always-on.

**Files:** `code/server/server.h`, `code/server/sv_init.c`, `code/server/sv_main.c`.
Depends on the Phase 2 `sh_stats` struct (fields `getstatus_global_would_drop` /
`getstatus_global_drop` already exist there).

---

## 3a — global getstatus gate

### cvars (`server.h` extern + register in `MOHAAShield_Init`)

```c
extern cvar_t *sv_shieldGetstatus;          /* 0 = off, 1 = shadow (count only), 2 = enforce */
extern cvar_t *sv_shieldGetstatusBurst;     /* token ceiling (see clamp below) */
extern cvar_t *sv_shieldGetstatusPeriodMs;  /* ms per token refill */
```
```c
    /* in MOHAAShield_Init(), safe defaults: shadow + generous */
    sv_shieldGetstatus         = Cvar_Get("sv_shieldGetstatus", "1", CVAR_ARCHIVE);
    sv_shieldGetstatusBurst    = Cvar_Get("sv_shieldGetstatusBurst", "100", CVAR_ARCHIVE);
    sv_shieldGetstatusPeriodMs = Cvar_Get("sv_shieldGetstatusPeriodMs", "10", CVAR_ARCHIVE);
```

### the bucket (near the other bucket globals in `sv_main.c`)

```c
static leakyBucket_t getstatusInboundBucket;
```

### the gate (top of `SVC_Status`, AFTER the single-player check, BEFORE `SVC_RateLimitAddress`)

```c
    if ( sv_shieldGetstatus && sv_shieldGetstatus->integer ) {
        int burst  = sv_shieldGetstatusBurst->integer;
        int period = sv_shieldGetstatusPeriodMs->integer;
        if ( period < 1 )  period = 1;      /* SVC_RateLimit divides by period -> never 0 */
        if ( burst  < 1 )  burst  = 1;
        if ( burst  > 127 ) burst = 127;    /* leakyBucket_t.burst is signed char */

        if ( SVC_RateLimit( &getstatusInboundBucket, burst, period ) ) {
            if ( sv_shieldGetstatus->integer >= 2 ) {   /* ENFORCE */
                sh_stats.getstatus_global_drop++;
                return;                                  /* skips the O(16384) per-IP scan */
            } else {                                     /* SHADOW: measure only */
                sh_stats.getstatus_global_would_drop++;
                /* fall through — behavior identical to stock */
            }
        }
    }
```

**Why the clamps matter:** `SVC_RateLimit` computes `interval / period` (period 0 →
divide-by-zero crash) and stores the token count in a **`signed char`** (`burst > 127` →
overflow → the limiter misbehaves). The clamps make any cvar value safe to set live.

**Rate math (so thresholds aren't arbitrary):** `SVC_RateLimit(b, burst, period)` refills 1
token per `period` ms, ceiling `burst`. Defaults `burst=100, period=10` = **~100 getstatus/s
sustained, burst 100** — generous vs. any legit browser load, ~3 orders of magnitude below a
flood. **Do not finalize this until Phase 2 shows your legit peak; then set enforce burst to
~5–10× that peak.** The gate is global, so when enforced it also suppresses legit status
queries during an attack — acceptable (status visibility degrades, gameplay does not,
connected players are on the sequenced path and unaffected).

## 3b — rotating allocator cursor (`SVC_BucketForAddress`, `sv_main.c`)

Replace the free-slot scan `for ( i = 0; i < MAX_BUCKETS; i++ )` with a rotating start.
Add a file-scope `static int sh_allocCursor = 0;` and rewrite the loop head/claim:

```c
    {
        int n;
        for ( n = 0; n < MAX_BUCKETS; n++ ) {
            int interval;
            i = ( sh_allocCursor + n ) % MAX_BUCKETS;   /* rotating start, not always 0 */
            bucket = &buckets[ i ];
            interval = now - bucket->lastTime;

            /* --- keep your existing reclaim block verbatim --- */
            if ( bucket->lastTime > 0 && ( interval > ( burst * period ) || interval < 0 ) ) {
                /* ... unlink from hash chain + Com_Memset(bucket,0,...) ... */
            }

            if ( bucket->type == NA_BAD ) {
                /* ... keep the existing claim block verbatim ... */
                sh_stats.new_source_allocs++;              /* from Phase 2 */
                sh_allocCursor = ( i + 1 ) % MAX_BUCKETS;  /* advance cursor past the claim */
                return bucket;
            }
        }
    }
    return NULL;   /* unchanged: all buckets live -> caller drops (fail-closed) */
```

This preserves every semantic (same reclaim rule, same fail-closed on a full table); it only
changes *where* the scan begins, so the common non-full case stops re-scanning a growing
prefix from 0. It is not a full fix for table-saturation thrash under extreme spoofing — the
global gate (3a, once enforced) is what prevents reaching that state for getstatus.

---

## Contingency from Phase 2 data

If Phase 2 shows the flood arriving as **`unknown`** (with `unk_sample` set) rather than
`getstatus`, then a `SVC_Status`-only gate won't catch it. In that case, add the **same cheap
global-bucket check** at the top of the `else { /* bad connectionless */ }` branch in
`SV_ConnectionlessPacket` (guarded by its own `sv_shieldUnknownOOB` cvar, same shadow/enforce
pattern). Don't build this pre-emptively — let the data place the guard.

## Verification (must all hold)

1. **Default is inert:** with `sv_shieldGetstatus 1` (shadow), a synthetic getstatus flood on
   a loopback test server increases `getstatus_global_would_drop` but **passes exactly as many
   responses as stock** (compare `getstatus_passed` and outbound behavior to a stock build).
2. **Enforce is correct and safe:** set `sv_shieldGetstatus 2` on the **test rig only**; the
   flood now increments `getstatus_global_drop`, response volume drops, and a simultaneously-
   connected test client (sequenced) stays in-game with no disruption. This is the release
   gate — a false player disconnect fails it.
3. **Cursor fix is transparent:** normal browser queries still get responses; connect/join
   still works; RSS flat. Toggle `sv_shieldGetstatus 0` and confirm behavior is identical to
   stock (the cursor change has no observable effect on correctness).
4. **Live-tunable:** changing the burst/period cvars at runtime takes effect without restart
   and never crashes even at extreme values (0, negative, >127) thanks to the clamps.
