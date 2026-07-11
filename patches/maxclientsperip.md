# Patch — cap client slots per source IP (`sv_maxclientsperip`)

**Status: CONFIRMED live attack vector** — single-source **slot exhaustion**. On 2026-07-11 one
IP (`156.193.58.49`) opened 27+ simultaneous client slots (`bashington`, 999 ping, one per
ephemeral source port), filling the server so real players were locked out. The connect
rate-limit doesn't stop this: ~27 connects from one IP over a few seconds stays under the 20/s
cap, so the slots fill without ever tripping the CPU guard. **Different attack from the connect
flood — this one consumes *slots*, not CPU.**

`sv_maxclientsperip` does not exist in this fork (verified: the cvar returns empty over rcon).
This adds it. It is the ioquake3-standard defense, adapted to this tree.

## The change

### 1. Register the cvar — in `SV_Init` (`sv_main.c`/`sv_init.c`), beside the other `Cvar_Get`s
```c
// 0 = disabled (default: no behaviour change on deploy). Set to e.g. 3 to cap slots per IP.
// CVAR_ARCHIVE (not LATCH) so it persists AND is tunable live over rcon without a restart.
sv_maxclientsperip = Cvar_Get( "sv_maxclientsperip", "0", CVAR_ARCHIVE );
```
(Declare `cvar_t *sv_maxclientsperip;` next to the other `sv_*` cvar globals.)

### 2. The guard — in `SV_DirectConnect` (`code/server/sv_client.c`)
Place it **after** the challenge is validated and the existing-connection (reconnect) scan,
**immediately before** the free-slot search (`state == CS_FREE`). That way it counts only
genuine, challenge-passed sessions and interacts correctly with reconnects:

```c
    // --- MOHAAShield: cap concurrent client slots per source IP (anti slot-exhaustion) ---
    if ( sv_maxclientsperip && sv_maxclientsperip->integer > 0 ) {
        int      perip = 0, i;
        client_t *cl;
        for ( i = 0, cl = svs.clients; i < sv_maxclients->integer; i++, cl++ ) {
            if ( cl->state <= CS_ZOMBIE ) {
                continue;   // skip free/zombie slots — never block a legit reconnect
            }
            if ( NET_CompareBaseAdr( from, cl->netchan.remoteAddress ) ) {
                perip++;
            }
        }
        if ( perip >= sv_maxclientsperip->integer ) {
            Com_DPrintf( "SV_DirectConnect: too many connections from %s (%d), dropping\n",
                NET_AdrToString( from ), perip );
            return;   // silent drop — no NET_OutOfBandPrint, so we don't reflect to the flooder
        }
    }
    // --- end MOHAAShield ---
```

**Verify in your fork before building** (as with the connect patch — don't trust names blindly):
`svs.clients`, `sv_maxclients->integer`, `client_t.state`, the `CS_FREE`/`CS_ZOMBIE` enum,
`cl->netchan.remoteAddress`, and `NET_CompareBaseAdr(netadr_t,netadr_t)` (compares IP, ignores
port). All are standard Q3-derived symbols; confirm the exact spelling in your tree.

## Why this design
- **Counts by *base* address (ignores port).** The attack's whole trick is many source ports
  from one IP; `NET_CompareBaseAdr` collapses them to one.
- **Skips `state <= CS_ZOMBIE`.** A player reconnecting (new NAT port, old slot going zombie)
  is not counted against themselves, so legit reconnects never get falsely blocked.
- **Only rejects a *new* connect — never disconnects an in-game player.** Changing the cvar, or
  an IP being over the cap, can only refuse a fresh connection. This preserves the core
  invariant (connected players are untouched); a false positive here is a refused *join*, which
  is acceptable, not a dropped player, which is not.
- **Default `0` = off.** Zero behaviour change on deploy; you enable it deliberately.
- **Silent drop** (Com_DPrintf, developer-gated) instead of a "too many connections" reply, so a
  flooder can't use it as a 1:1 reflector.

## Choosing the value (important — you have shared-IP legit players)
Your `status` showed 5 "legit" clients on a single IP (`207.60.65.248`). **Set
`sv_maxclientsperip` to at least your largest genuine same-IP group**, or you'll block real
players (a LAN/café/household behind one NAT). Start at `sv_maxclientsperip 4` or `5` and lower
it only if you confirm nobody legit shares an IP. `2` is ideal for a pure-public server where
every player is a distinct household — but not if those 5 are real.

## Known limits (set expectations)
- **Distributed slot floods:** an attacker with N IPs can still take `cap × N` slots. `cap=3`
  with 22 IPs still fills 64. This **fully stops the confirmed single-source case** and forces an
  attacker to source many IPs, but isn't a complete answer to a botnet-scale slot flood — that
  needs connection-rate limits per IP + the existing bans, and ultimately reserved-slot / auth.
- **Not a CPU defense.** Orthogonal to the connect rate-limit and the nft/XDP work; keep all of
  them. This one protects *slots*; those protect *CPU*.

## Verify (must all hold)
1. **Builds; starts; default off.** With `sv_maxclientsperip 0` the server behaves exactly as
   before.
2. **Cap enforced:** set `sv_maxclientsperip 3`; open 3 connections from one IP → all accepted;
   a 4th from that same IP → refused; a connection from a **different** IP → still accepted.
3. **No legit disconnect:** players already in-game are unaffected when you change the cvar or
   when an IP hits the cap (only the new connect is refused).
4. **Reconnect works:** disconnect and rejoin from the same IP repeatedly → always succeeds
   (old slot zombie/freed, not counted).
5. **Live-tunable:** `rcon sv_maxclientsperip 2` takes effect with no restart.
