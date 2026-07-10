#!/usr/bin/env bash
# MOHAAShield — make the per-source OOB rate limit PERMANENT (survive reboot + nft reloads).
#
# The live rule from oob-ratelimit.sh is memory-only: a reboot, or any `nft -f /etc/nftables.conf`
# (e.g. a ban import), atomically replaces the ruleset and WIPES it. This bakes the same chain
# into /etc/nftables.conf so it comes back automatically. Safe to re-run: idempotent, validates
# the whole proposed ruleset first, backs up the config, reloads atomically, and re-imports the
# permanent ban sets afterward (the reload empties file-defined sets). Drops nothing sequenced.
#
#   sudo bash host/nftables/persist-oob-ratelimit.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"
PORTS_NFT="${PORTS_NFT:-12203, 12300}"
RATE="${RATE:-20}"; BURST="${BURST:-40}"; SIZE="${SIZE:-65535}"
IMPORT_BANS="${IMPORT_BANS:-/usr/local/sbin/mohaa-import-bans}"

[ -f "$NFT_CONF" ] || { echo "no $NFT_CONF found"; exit 1; }

if grep -q 'chain oob_ratelimit' "$NFT_CONF"; then
  echo "oob_ratelimit already present in $NFT_CONF — nothing to do."
  echo "verify: sudo nft list chain inet mohaashield oob_ratelimit"
  exit 0
fi

if ! grep -Eq '^[[:space:]]*table inet mohaashield[[:space:]]*\{' "$NFT_CONF"; then
  echo "Could not find 'table inet mohaashield {' in $NFT_CONF; not editing automatically." >&2
  echo "Add this chain inside your table, then run: sudo nft -f $NFT_CONF" >&2
  exit 1
fi

TMP="$(mktemp)"
awk -v ports="$PORTS_NFT" -v rate="$RATE" -v burst="$BURST" -v size="$SIZE" '
  /^[[:space:]]*table inet mohaashield[[:space:]]*\{/ && !ins {
    print
    print "    chain oob_ratelimit {"
    print "        type filter hook prerouting priority -305"
    print "        policy accept"
    print "        udp dport { " ports " } @th,64,32 0xffffffff \\"
    print "            meter oob_src4 size " size " { ip saddr limit rate over " rate "/second burst " burst " packets } \\"
    print "            counter drop"
    print "    }"
    ins = 1
    next
  }
  { print }
' "$NFT_CONF" > "$TMP"

# Validate the whole proposed ruleset before touching the live file.
if ! nft -c -f "$TMP"; then
  echo "Validation failed; $NFT_CONF left unchanged. Proposed file kept at $TMP" >&2
  exit 1
fi

BACKUP="${NFT_CONF}.mohaashield.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$NFT_CONF" "$BACKUP"
cat "$TMP" > "$NFT_CONF"          # overwrite content, preserve file mode/owner
rm -f "$TMP"

nft -f "$NFT_CONF"               # atomic reload (empties file-defined sets)
if [ -x "$IMPORT_BANS" ]; then
  "$IMPORT_BANS"                 # repopulate permanent player/ddos ban sets
fi

echo "persisted: oob_ratelimit baked into $NFT_CONF (survives reboot + ban reloads). Backup: $BACKUP"
echo "verify:    sudo nft list chain inet mohaashield oob_ratelimit"
