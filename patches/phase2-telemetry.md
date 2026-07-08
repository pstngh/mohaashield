# Phase 2 — Connectionless telemetry (observe-only)

**Goal:** aggregated, per-window visibility into connectionless-command and sequenced-packet
activity, with **zero behavioral change** (no drops, no altered responses, no per-packet
logging). This produces the attack table and the legit baseline that later phases need.

**Approach:** a single flat counter struct incremented at a handful of call sites (single-
threaded engine → no atomics), printed once per window from `SV_Frame`, then reset. Counters
are always incremented (a `uint64_t++` is negligible); only the *print* is cvar-gated.

**Files touched:** `code/server/server.h`, `code/server/sv_main.c`, `code/server/sv_init.c`
(and optionally `code/server/sv_client.c` to mirror getinfo/getchallenge). No new build file,
no CMake change. *(Alternative if you prefer isolation: put the definitions in a new
`code/server/sv_mohaashield.c` and add it to your server sources — functionally identical.)*

> Verify against your fork first: confirm `SV_ConnectionlessPacket` reads the command at
> `msg->data[5]` (4-byte `-1` + 1 direction byte). See `patches/README.md` for why this
> matters. If your offset differs, keep the counters but adjust the sample-capture line.

---

## Step 1 — counter struct + externs  (`server.h`)

Add near the other server declarations:

```c
typedef struct {
    /* connectionless "received" — counted BEFORE rate limiting so floods are visible */
    uint64_t oob_total;
    uint64_t oob_getstatus, oob_getinfo, oob_getchallenge;
    uint64_t oob_connect, oob_authorize, oob_rcon, oob_disconnect, oob_unknown;
    char     oob_unknown_sample[32];   /* first unrecognized command token this window */

    /* getstatus outcome (mirror to _info/_challenge structs if you want them too) */
    uint64_t getstatus_perip_drop, getstatus_outbound_drop, getstatus_passed;
    uint64_t getstatus_global_would_drop, getstatus_global_drop;  /* filled by Phase 3 */

    /* churn proxy: fresh per-IP bucket allocations (new sources hitting the limiter) */
    uint64_t new_source_allocs;

    /* sequenced path */
    uint64_t seq_valid_match, seq_unknown_source, seq_bad_netchan;
} mohaashieldStats_t;

extern mohaashieldStats_t sh_stats;

extern cvar_t *sv_shieldStats;        /* 0 = no print, 1 = print active windows */
extern cvar_t *sv_shieldStatsWindow;  /* window length, ms */

void MOHAAShield_Init(void);        /* register cvars — call from SV_Init */
void MOHAAShield_StatsTick(void);   /* print+reset if window elapsed — call from SV_Frame */
```

*(If `uint64_t` isn't already visible here, use your tree's 64-bit unsigned type or
`unsigned long long`.)*

## Step 2 — definitions, init, tick  (`sv_main.c`)

Near the existing bucket globals:

```c
mohaashieldStats_t sh_stats;
cvar_t *sv_shieldStats;
cvar_t *sv_shieldStatsWindow;

void MOHAAShield_Init(void) {
    sv_shieldStats       = Cvar_Get("sv_shieldStats", "1", CVAR_ARCHIVE);
    sv_shieldStatsWindow = Cvar_Get("sv_shieldStatsWindow", "5000", CVAR_ARCHIVE);
}

void MOHAAShield_StatsTick(void) {
    static int windowStart = 0;
    int now = Sys_Milliseconds();
    int window = (sv_shieldStatsWindow ? sv_shieldStatsWindow->integer : 5000);
    int elapsed;

    if (window < 1000) window = 1000;          /* clamp */
    if (windowStart == 0) windowStart = now;
    elapsed = now - windowStart;
    if (elapsed < 0) { windowStart = now; return; }   /* Sys_Milliseconds wrap */
    if (elapsed < window) return;

    /* print only when there was activity, so idle windows stay silent */
    if (sv_shieldStats && sv_shieldStats->integer &&
        (sh_stats.oob_total || sh_stats.seq_unknown_source || sh_stats.seq_bad_netchan)) {
        float s = elapsed / 1000.0f;
        Com_Printf("MOHAASHIELD  window=%.1fs\n", s);
        Com_Printf("  OOB recv=%llu  getstatus=%llu getinfo=%llu getchallenge=%llu "
                   "connect=%llu rcon=%llu unknown=%llu%s%s\n",
            (unsigned long long)sh_stats.oob_total,
            (unsigned long long)sh_stats.oob_getstatus,
            (unsigned long long)sh_stats.oob_getinfo,
            (unsigned long long)sh_stats.oob_getchallenge,
            (unsigned long long)sh_stats.oob_connect,
            (unsigned long long)sh_stats.oob_rcon,
            (unsigned long long)sh_stats.oob_unknown,
            sh_stats.oob_unknown_sample[0] ? "  unk_sample=" : "",
            sh_stats.oob_unknown_sample);
        Com_Printf("  getstatus perip_drop=%llu outbound_drop=%llu passed=%llu "
                   "global_would_drop=%llu global_drop=%llu\n",
            (unsigned long long)sh_stats.getstatus_perip_drop,
            (unsigned long long)sh_stats.getstatus_outbound_drop,
            (unsigned long long)sh_stats.getstatus_passed,
            (unsigned long long)sh_stats.getstatus_global_would_drop,
            (unsigned long long)sh_stats.getstatus_global_drop);
        Com_Printf("  new_src=%llu  seq match=%llu unknown_src=%llu bad_netchan=%llu\n",
            (unsigned long long)sh_stats.new_source_allocs,
            (unsigned long long)sh_stats.seq_valid_match,
            (unsigned long long)sh_stats.seq_unknown_source,
            (unsigned long long)sh_stats.seq_bad_netchan);
    }

    memset(&sh_stats, 0, sizeof(sh_stats));   /* reset window (bounded, no growth) */
    windowStart = now;
}
```

## Step 3 — wire the hooks

- In `SV_Init` (`sv_init.c`), alongside the other `Cvar_Get` calls: `MOHAAShield_Init();`
- In `SV_Frame` (`sv_main.c`), once per frame (top is fine): `MOHAAShield_StatsTick();`

## Step 4 — count connectionless commands  (`SV_ConnectionlessPacket`, `sv_main.c`)

After `c = Cmd_Argv(0);`, add `sh_stats.oob_total++;` then increment per branch. Edit the
existing dispatch chain to:

```c
    c = Cmd_Argv(0);
    sh_stats.oob_total++;
    Com_DPrintf ("SV packet %s : %s\n", NET_AdrToString(from), c);

    if (!Q_stricmp(c, "getstatus")) {
        sh_stats.oob_getstatus++;   SVC_Status( from );
    } else if (!Q_stricmp(c, "getinfo")) {
        sh_stats.oob_getinfo++;     SVC_Info( from );
    } else if (!Q_stricmp(c, "getchallenge")) {
        sh_stats.oob_getchallenge++; SV_GetChallenge(from);
    } else if (!Q_stricmp(c, "connect")) {
        sh_stats.oob_connect++;     SV_DirectConnect( from );
    } else if (!Q_stricmp(c, "authorizeThis")) {
        sh_stats.oob_authorize++;   SV_GamespyAuthorize( from, Cmd_Argv(1) );
    } else if (!Q_stricmp(c, "rcon")) {
        sh_stats.oob_rcon++;        SVC_RemoteCommand( from, msg );
    } else if (!Q_stricmp(c, "disconnect")) {
        sh_stats.oob_disconnect++;  /* existing no-op */
    } else {
        sh_stats.oob_unknown++;
        if (sh_stats.oob_unknown_sample[0] == '\0' && c && c[0]) {
            Q_strncpyz(sh_stats.oob_unknown_sample, c, sizeof(sh_stats.oob_unknown_sample));
        }
        Com_DPrintf ("bad connectionless packet from %s:\n%s\n", NET_AdrToString(from), s);
    }
```

## Step 5 — count getstatus outcomes  (`SVC_Status`, `sv_main.c`)

At the three existing decision points:

```c
    if ( SVC_RateLimitAddress( from, 10, 1000 ) ) {
        sh_stats.getstatus_perip_drop++;                 /* ADD */
        Com_DPrintf( ... );
        return;
    }
    if ( SVC_RateLimit( &outboundLeakyBucket, 10, 100 ) ) {
        sh_stats.getstatus_outbound_drop++;              /* ADD */
        Com_DPrintf( ... );
        return;
    }
    ...
    sh_stats.getstatus_passed++;                          /* ADD, just before the response */
    SV_NET_OutOfBandPrint( &svs.netprofile, from, "statusResponse\n%s\n%s", infostring, status );
```

*(Optional: mirror the same three counters into `SVC_Info` and `SV_GetChallenge` with their
own struct fields if you want per-command drop visibility. Not required for v1.)*

## Step 6 — churn proxy  (`SVC_BucketForAddress`, `sv_main.c`)

In the free-slot claim block, right after a fresh `NA_BAD` bucket is claimed
(`bucket->type = address.type; ... bucket->lastTime = now;`), add:

```c
        sh_stats.new_source_allocs++;   /* a source we hadn't seen recently */
```

## Step 7 — sequenced-path counters  (`SV_PacketEvent`, `sv_main.c`)

In the matched-client block and the no-match tail:

```c
        if (SV_Netchan_Process(cl, msg)) {
            sh_stats.seq_valid_match++;                  /* ADD */
            if (cl->state != CS_ZOMBIE) {
                cl->lastPacketTime = svs.time;
                SV_ExecuteClientMessage( cl, msg );
            }
        } else {
            sh_stats.seq_bad_netchan++;                  /* ADD: matched addr+qport but checksum/seq failed */
        }
        return;
    }

    sh_stats.seq_unknown_source++;                       /* ADD: drives the OOB "disconnect" reflection */
    SV_NET_OutOfBandPrint( &svs.netprofile, from, "disconnect" );
```

---

## Verification (must all hold before shipping)

1. **Builds** with your normal server build; server starts normally.
2. **Counters move correctly:** from another host, run a server browser / `gamedig` / a few
   manual queries and confirm the window print shows matching `getstatus`/`getinfo`/
   `getchallenge`/`connect` counts. Note whether a `getstatus` query lands in `getstatus` or
   in `unknown` with `unk_sample=` set — this answers the `data[5]` question.
3. **No per-packet spam:** with `developer 0`, the only new output is the once-per-window
   block, and idle windows print nothing.
4. **Invariant — no player impact:** connect a real client (or a bot), leave it in-game for
   several windows, and confirm it is never dropped and `seq_valid_match` climbs while the
   client's play is unaffected. This is the release gate.
5. **Bounded:** `sizeof(mohaashieldStats_t)` is fixed; the struct is memset each window;
   there is no new allocation. Confirm RSS is flat over time.

## What we learn (drives Phase 3/4 thresholds)
- The **legit** aggregate rates of each OOB command (needed to set any enforce threshold).
- Under a real attack: which counter explodes (`getstatus` vs `unknown`+sample vs `connect`
  vs `seq_unknown_source`), the `new_src` churn rate (spoofing signal), and whether the
  outbound limiter is already absorbing it. That determines exactly where mitigation goes.
