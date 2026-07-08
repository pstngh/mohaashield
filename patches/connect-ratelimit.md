# Priority patch — rate-limit `connect` (`SV_DirectConnect`)

**Status: CONFIRMED live attack vector** — see `../docs/incidents/2026-07-08-connect-flood.md`
(88,230 connect packets = 75% of an inbound OOB flood on the production box). `connect` is the
**only** connectionless command with no rate limiter; every other OOB handler already has the
exact guard it needs. This patch makes `connect` consistent with them. Small, auditable, and it
directly stops the confirmed flood.

## The change — `SV_DirectConnect` in `code/server/sv_client.c`

Add the **same two rate-limit calls `SV_GetChallenge` already uses**, at the very TOP of
`SV_DirectConnect` (before the userinfo copy, ban check, and the 2048-iteration challenge
scan — so a flood is rejected before any of that work):

```c
void SV_DirectConnect( netadr_t from ) {
    ...
    // --- MOHAAShield: connect is otherwise the only un-throttled OOB command ---
    // Per-source cap (10 burst, then 1/sec) — mirrors getstatus/getinfo/getchallenge.
    if ( SVC_RateLimitAddress( from, 10, 1000 ) ) {
        Com_DPrintf( "SV_DirectConnect: rate limit from %s exceeded, dropping\n",
            NET_AdrToString( from ) );
        return;
    }
    // Shared outbound cap — bounds the "No or bad challenge" reflection.
    if ( SVC_RateLimit( &outboundLeakyBucket, 10, 100 ) ) {
        return;
    }
    // --- end MOHAAShield ---

    // ... existing body (Q_strncpyz userinfo, SV_IsBanned, challenge scan, etc.) ...
}
```

`SVC_RateLimitAddress` / `outboundLeakyBucket` already exist in `sv_main.c` and are used by the
other handlers — no new machinery. `outboundLeakyBucket` may need an `extern` in scope (it is
non-static; `SV_GetChallenge` in this same file already references it, so it's already visible).

## Why these values
- `(10, 1000)` = burst 10 then 1/sec per source. A legit player connects **once** per join
  (well under burst 10, even for a reconnect), so **real joins are unaffected**. A single-IP
  flood like `41.44.154.180` (≈1,337 connect/s) collapses to 1/s — the 2048-entry challenge
  scan and the reflection response stop firing for it.
- Identical to `getstatus`/`getinfo`/`getchallenge`, so it's provably no stricter than what the
  server already imposes on those commands.

## Known limits (so you set expectations)
- **Multi-IP / spoofed connect floods:** the per-source limiter still calls
  `SVC_BucketForAddress` (the O(16384) scan) for each new IP. For the *confirmed* few-source
  attack this is a non-issue; for a spoofed-many-IP variant, the durable answer is the global
  OOB gate at the top of `SV_ConnectionlessPacket` (see `phase3-getstatus-shadow-guard.md`
  §3a′), which is O(1) and caps `connect` regardless of source count.
- The connect-path `Huff_Decompress` runs in `SV_ConnectionlessPacket` *before* dispatch, so
  this handler-level limit doesn't save that step (cheap relative to the 2048-scan + response).
  The global gate (3a′) would save it too.

## Verify (must all hold)
1. **Builds; server starts.** A real client can still join normally (connect once → in-game).
2. **Reconnect works:** disconnect + rejoin a few times quickly — still fine (burst 10).
3. **Flood is capped:** replay/point a connect flood from one source at a test server → its
   accepted-connect rate drops to ~1/s, outbound "bad challenge" replies to it stop, CPU falls.
4. **No legit disconnect:** a player already in-game is completely unaffected (this only touches
   the connectionless `connect` handler, never the sequenced channel).
