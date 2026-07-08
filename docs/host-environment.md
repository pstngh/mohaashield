# Host environment (OVH box, as built)

Snapshot of the production OVH VPS and the operator-built firewall, with MOHAAShield's review.

## Facts
- OVH VPS, Debian 13 (trixie), kernel 6.12, `virtio_net`, single RX queue, 256-slot ring.
- Public IPv4 `51.75.171.179` on `ens3` (also has IPv6 `2001:41d0:801:2000::3f61`).
- **`omohaaded` listens on UDP 12203 AND UDP 12300** (both `0.0.0.0`, i.e. IPv4-only). SSH on
  TCP 22. Exim local-only (TCP 25 loopback). systemd-resolved stub on 127.0.0.53; LLMNR
  disabled.
- Flight recorder + attack-watch installed by MOHAAShield this session (capture **both** game
  ports).

## Operator-built firewall (`/etc/nftables.conf`, `table inet mohaashield`)
- Sets: `player_bans_v4` (1075 collapsed CIDRs from the old NFO list), `ddos_bans_v4` (empty),
  `dynamic_bans_v4` (`flags timeout`, default 30m).
- `input` policy **drop**: lo accept → `ct invalid drop` → ban-set drops for udp
  `{12203,12300}` (**above** `ct established` — correct, so bans win) → `ct established,related
  accept` → ICMP/ICMPv6 → tcp 22 → udp `{12203,12300}` accept.
- `forward` drop, `output` accept.
- Ban import: `/usr/local/sbin/mohaa-import-bans` (validates/normalizes v4 CIDRs; reloads the
  two permanent sets; leaves `dynamic_bans_v4` alone) + `mohaa-bans.service` reloads on boot.

## Review
**Good, and well-aligned with MOHAAShield:**
- `dynamic_bans_v4` (timeout set) is exactly the **Layer-4 hook** MOHAAShield's control plane
  will use — add an offending IP/prefix with a bounded timeout (auto-expiry, no permanent
  spoof-poisoning). Nothing to change; it's ready for when data justifies auto-bans.
- Ban-set drops correctly ordered before `ct established`.

**One issue that matters — conntrack under UDP flood:**
- With `policy drop` + `ct state` rules, **every** inbound game packet is conntracked. A
  spoofed-source UDP flood (random src IP/port) creates a new conntrack entry per packet and
  can exhaust `nf_conntrack_max` in seconds → `nf_conntrack: table full, dropping packet`,
  which drops **legit** traffic and burns CPU. This is a classic way a stateful firewall turns
  a flood into self-inflicted downtime — a plausible contributor to the lag you already see.
- The game path doesn't need conntrack: the ban drops match on `saddr` statelessly and the
  final rule accepts `udp dport {12203,12300}` regardless of ct state. So **bypass conntrack
  for the game ports** with a `raw`/prerouting `notrack` rule (see the runbook). It drops
  nothing, is reversible, and is standard practice for game servers — safe to add now.
- When the recorder catches a flood, confirm with `conntrack -C` vs `sysctl
  net.netfilter.nf_conntrack_max` and `dmesg | grep -i conntrack`.

**Minor:**
- Ban sets are IPv4-only, which is fine while `omohaaded` binds IPv4 only. If IPv6 game
  service is ever enabled, add parallel `ipv6_addr` sets.
- SSH is open to the world; consider source-restricting or rate-limiting it (operator's call).

## Recommended `notrack` rule (add to `table inet mohaashield`)
```
chain raw_prerouting {
    type filter hook prerouting priority raw; policy accept;
    udp dport { 12203, 12300 } notrack
}
```
This keeps game UDP out of conntrack while leaving bans, `ct invalid` (for other traffic), and
SSH state handling intact. Reload with `sudo nft -f /etc/nftables.conf`.
