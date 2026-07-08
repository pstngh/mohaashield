# OpenMoHAA source analysis (verified)

Reference snapshot of the OpenMoHAA server networking code that MOHAAShield protects.
Verified against `openmoh/openmohaa` @ **`main`**, project **v0.83.0**. Last relevant
`sv_main.c` change (2025-12-20) was a net-profiling field rename — the rate-limiter
logic is unchanged from the ioquake3-derived implementation.

> This is the load-bearing knowledge for every threshold and mitigation decision.
> When upgrading OpenMoHAA, re-verify this file against the new source before shipping patches.

## Connectionless (out-of-band) command dispatch

A connectionless packet is `FF FF FF FF` (`*(int*)data == -1`), followed — in this
MOHAA build — by **one direction byte**, then the command line. `SV_ConnectionlessPacket`
(`code/server/sv_main.c`) tokenizes and dispatches via `Q_stricmp`:

| Command | Handler | File | Rate-limited? |
|---|---|---|---|
| `getstatus` | `SVC_Status` | `sv_main.c` | **Yes** — per-IP `(10,1000)` + shared outbound `(10,100)` |
| `getinfo` | `SVC_Info` | `sv_main.c` | **Yes** — same two limiters (shares the outbound bucket) |
| `getchallenge` | `SV_GetChallenge` | `sv_client.c` | **Yes** — per-IP `(10,1000)` + outbound `(10,100)`, before any table work |
| `connect` | `SV_DirectConnect` | `sv_client.c` | **NO** — un-throttled (heaviest pre-auth path) |
| `authorizeThis` | `SV_GamespyAuthorize` | `sv_client.c` | n/a — vestigial (GameSpy is dead) |
| `rcon` | `SVC_RemoteCommand` | `sv_main.c` | Yes — per-IP `(10,1000)` + shared bad-password static bucket `(10,1000)` |
| `disconnect` | (no-op) | `sv_main.c` | n/a |

The dispatcher has **no length/flood guard**; per-command `strlen(Cmd_Argv(1)) > 128`
checks live *inside* the handlers, *after* the rate limiters.

### Observed wire layout (live capture 2026-07-08)

A real inbound `getstatus` from a server browser was captured on the production box:

```
ff ff ff ff | 02 | 67 65 74 73 74 61 74 75 73        (14-byte UDP payload)
 -1 marker    dir  "g  e  t  s  t  a  t  u  s"        (no trailing newline)
```

Legit OOB = 4-byte marker + **1 direction byte (`0x02`)** + command → command read at
`data[5]`, matching the parser's `MSG_ReadLong` + `MSG_ReadByte` skip. It produced a 975-byte
`statusResponse` (~70× payload amplification; the outbound bucket caps this to ~10/s ≈
~80 kbps, so it is **not** an abusable amplifier).

**Consequence for the confirmed attack.** The NFO attack shape
`ff ff ff ff "getstatus" 0a` has the command at `data[4]`, **no** direction byte, trailing
newline. Parsed from `data[5]` it tokenizes to **`etstatus`** → the **unknown/bad
connectionless** branch. So the historical flood **never reaches `SVC_Status`**, never hits
the O(16384) bucket scan, and sends no reply — its only cost is unthrottled inbound
`MSG_ReadStringLine` + `Cmd_TokenizeString` + `Q_stricmp` chain in the single-threaded loop.
*(Inference from the verified parser + this capture + the NFO signature; Phase 2's `unknown`
counter + `unk_sample` will confirm empirically during the next attack — expect `etstatus`.)*
This is why the primary Phase 3 guard belongs at the **top of `SV_ConnectionlessPacket`**, not
only in `SVC_Status`.

## The leaky-bucket rate limiter (`code/server/sv_main.c`)

Clock is **`Sys_Milliseconds()`** (not `svs.time`). Structures:

```
#define MAX_BUCKETS 16384
#define MAX_HASHES  1024
static leakyBucket_t buckets[MAX_BUCKETS];
static leakyBucket_t *bucketHashes[MAX_HASHES];
leakyBucket_t outboundLeakyBucket;   // shared by getstatus + getinfo + getchallenge
```

**`SVC_RateLimit(bucket, burst, period)` semantics** — a token bucket:
- refills **1 token every `period` ms**, ceiling = `burst`;
- passes (`qfalse`) iff `bucket->burst < burst`, then consumes one token;
- a `NULL` bucket returns `qtrue` (**drop — fail-closed**);
- handles `Sys_Milliseconds()` wrap via the `interval < 0` reset branch.

Therefore, decoded to real rates:

| Call site | Params | Sustained | Burst |
|---|---|---|---|
| Per-IP (status/info/challenge/rcon) | `(10, 1000)` | **1 req/sec/IP** | 10 |
| Shared outbound (status/info/challenge) | `(10, 100)` | **10 resp/sec global** | 10 |

> **Correction to common assumptions:** `(10,1000)` is **1/sec sustained**, not "10/sec".
> The `(10,100)` outbound cap means **amplification is already well-contained** — the box
> emits at most ~10 status/info/challenge replies/sec regardless of flood size. The residual
> gap is **inbound CPU**, not outbound bandwidth.

**`SVC_BucketForAddress(address, burst, period)`** — the algorithmic hot spot:
1. Walk the address's hash chain (`bucketHashes[hash]`) for an exact IP match — cheap.
2. On miss, **linearly scan `buckets[0..MAX_BUCKETS)` from index 0**, reclaiming any
   bucket idle longer than `burst*period` ms, and claim the first free (`NA_BAD`) slot.
3. If all 16384 are live, return `NULL` → the caller drops (fail-closed).

Every **new/spoofed source IP** pays step 2 — an **O(16384) scan** — *before* the cheap
global outbound gate runs. Under a spoofed-source flood this is per-packet CPU cost even
though the response itself is cheaply suppressed. This is the mechanism behind the confirmed
historical `getstatus` flood.

## Sequenced (in-game) packet path (`SV_PacketEvent`, `sv_main.c`)

Non-`-1` packets: read sequence + `qport` (wire bytes 4–5), then an `O(≤64)` scan over
`svs.clients` matching **base address AND qport**. On match → `SV_Netchan_Process` →
`SV_ExecuteClientMessage`. **On no match → the server emits an OOB `"disconnect"` to the
source, un-throttled** (a weak reflection primitive; ~1:1 amplification).

`Netchan_Process` (`code/qcommon/net_chan.c`) verifies
`NETCHAN_GENCHECKSUM(challenge, sequence)` **before** fragment reassembly, so a spoofed
packet cannot inject into a live client's stream. **Connected players are cryptographically
gated** — this is why shield logic must never touch the sequenced path.

## Connect path (`SV_DirectConnect`, `sv_client.c`) — the softest un-throttled lever

Per `connect` packet, *before* the challenge is validated (all attacker-reachable without a
valid challenge, and with **no rate limiter**):
- `Huff_Decompress` of the connect payload;
- several `Info_ValueForKey` scans over a ≤1350-byte userinfo;
- a **2048-iteration `NET_CompareAdr` scan** of `svs.challenges[]` before the
  "No or bad challenge" reject.

A client slot is consumed **only after** the challenge passes (into a `static` scratch
`client_t` — no per-connect heap). Challenge value is `((rand()<<16)^rand())^svs.time`
(weak PRNG — defense-in-depth concern only).

## Fixed-size state (no unbounded allocation anywhere in these paths)

| State | Size | Where |
|---|---|---|
| `svs.challenges[]` | `MAX_CHALLENGES = 2048` (evict-oldest) | `server.h` |
| `buckets[]` | `MAX_BUCKETS = 16384` | `sv_main.c` |
| `svs.clients[]` | `≤ MAX_CLIENTS = 64`, `Z_Malloc`'d once at startup | `sv_init.c` |

**Memory exhaustion is not a surface.** The exposure is **CPU + reflection bandwidth**.

## Logging & cvars (for the telemetry patch)

- `Com_Printf` (unconditional), `Com_DPrintf` (gated by `developer` cvar), `Com_Error`
  (longjmp, escalates to fatal on >3 errors/100 ms). **No built-in throttled/aggregated
  logger** — any counters we add must aggregate and print at most once per window.
- Cvars: `Cvar_Get(name, default, flags)` registered in `SV_Init` (`sv_init.c`),
  `extern cvar_t *sv_...` in `server.h`, read via `->integer` / `->value` / `->string`.
  Mirror existing server cvars (`sv_maxclients`, `sv_floodProtect`, ...). Use
  `CVAR_ARCHIVE` (live-tunable), **not** `CVAR_LATCH`, for shield thresholds.

## Build (Debian)

CMake ≥3.25, C17/C++17. Deps: `cmake ninja-build clang lld flex bison libsdl2-dev
libopenal-dev libcurl4-openssl-dev`. Out-of-source: `cmake ../` → `cmake --build .` →
`cmake --install .`. Server-only: `-DBUILD_CLIENT=0`. **Dedicated-server binary =
`omohaaded`** (`set(SERVER_NAME omohaaded)` in `cmake/identity.cmake`). Launch:
`./omohaaded +set com_target_game 0 +exec server_opm.cfg`. Prebuilt releases also exist.
