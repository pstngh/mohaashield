#!/usr/bin/env bash
# MOHAAShield — per-source OOB (connectionless) rate limit at the kernel, for instant flood relief.
#
# Drops ONLY connectionless packets — those whose first 4 payload bytes are 0xffffffff:
# getstatus / getinfo / getchallenge / connect — that exceed a PER-SOURCE-IP rate on the game
# ports. In-game players use *sequenced* packets (payload does NOT start 0xffffffff), so they are
# NEVER matched and NEVER dropped. Because the limit is per source IP (not global), a single
# flooding IP is throttled while legit joiners on other IPs sail through.
#
# Safety: bounded memory (the per-source meter is size-capped and auto-expires), validates the
# ruleset before touching the live config, isolated in its own chain, fully reversible (--remove),
# and drops nothing on the sequenced/in-game path. This is the confirmed-few-source relief lever;
# a spoofed-many-IP flood needs the source-level global gate too (see patches/).
#
#   sudo bash host/nftables/oob-ratelimit.sh                 # apply (20/s per source, burst 40)
#   sudo bash host/nftables/oob-ratelimit.sh --rate 30 --burst 60
#   sudo bash host/nftables/oob-ratelimit.sh --remove        # take it back off
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

TABLE="${TABLE:-inet mohaashield}"
CHAIN="${CHAIN:-oob_ratelimit}"
METER="${METER:-oob_src4}"
PORTS_NFT="${PORTS_NFT:-12203, 12300}"
RATE="${RATE:-20}"       # connectionless packets/sec allowed per source IP
BURST="${BURST:-40}"     # burst allowance per source IP
SIZE="${SIZE:-65535}"    # max source IPs tracked at once (bounds memory)
REMOVE=0
while [ $# -gt 0 ]; do case "$1" in
  --rate)   RATE="${2:?}";  shift ;;
  --burst)  BURST="${2:?}"; shift ;;
  --remove) REMOVE=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac; shift; done

# The operator's mohaashield table must already be loaded.
if ! nft list table $TABLE >/dev/null 2>&1; then
  echo "table '$TABLE' not found — is your nftables ruleset loaded? (nft list ruleset)" >&2
  exit 1
fi

# Idempotent teardown: drop our chain (and its meter set) if a prior run left them.
nft flush chain  $TABLE $CHAIN 2>/dev/null || true
nft delete chain $TABLE $CHAIN 2>/dev/null || true
nft delete set   $TABLE $METER 2>/dev/null || true
if [ "$REMOVE" = 1 ]; then echo "removed: chain $TABLE $CHAIN"; exit 0; fi

# priority -305 = before raw/notrack (-300) and the ban-list, so flood dies at the earliest hook.
# @th,64,32 == the 32 bits right after the 8-byte UDP header == first 4 payload bytes (the OOB
# marker). meter keyed on ip saddr => each source IP gets its own leaky bucket; "over" => drop.
RULESET="add chain $TABLE $CHAIN { type filter hook prerouting priority -305 ; policy accept ; }
add rule  $TABLE $CHAIN udp dport { $PORTS_NFT } @th,64,32 0xffffffff \
    meter $METER size $SIZE { ip saddr limit rate over ${RATE}/second burst ${BURST} packets } \
    counter drop"

# Validate against the live ruleset first; change nothing if the syntax isn't accepted here.
if ! nft -c -f - <<<"$RULESET"; then
  echo "validation failed — nothing changed. Your nft build may want slightly different syntax;" >&2
  echo "paste the error above to MOHAAShield and it'll adjust." >&2
  exit 1
fi
nft -f - <<<"$RULESET"

echo "applied: per-source connectionless cap ${RATE}/s (burst ${BURST}) on { $PORTS_NFT }"
echo "  in-game (sequenced) players are never matched; only OOB floods are throttled per source."
echo
echo "watch it work:  watch -n1 'sudo nft list chain $TABLE $CHAIN'   # counter climbs during a flood"
echo "remove:         sudo bash $0 --remove"
