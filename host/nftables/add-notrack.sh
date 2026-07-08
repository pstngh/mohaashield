#!/usr/bin/env bash
# MOHAAShield — bypass conntrack for the MOHAA game UDP ports.
#
# Adds a raw/prerouting `notrack` chain to the operator's nftables ruleset so a spoofed
# UDP flood cannot exhaust nf_conntrack_max (which would start dropping legit players).
# It drops nothing. Safe to re-run: idempotent, validates before applying, backs up the
# config, reloads atomically, and re-imports the permanent ban sets afterward.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"
PORTS_NFT="${PORTS_NFT:-12203, 12300}"
IMPORT_BANS="${IMPORT_BANS:-/usr/local/sbin/mohaa-import-bans}"

[ -f "$NFT_CONF" ] || { echo "no $NFT_CONF found"; exit 1; }

if grep -q 'chain raw_prerouting' "$NFT_CONF"; then
  echo "notrack chain already present in $NFT_CONF — nothing to do."
  exit 0
fi

if ! grep -Eq '^[[:space:]]*table inet mohaashield[[:space:]]*\{' "$NFT_CONF"; then
  echo "Could not find 'table inet mohaashield {' in $NFT_CONF; not editing automatically." >&2
  echo "Add this chain inside your table, then run: sudo nft -f $NFT_CONF" >&2
  printf '    chain raw_prerouting {\n        type filter hook prerouting priority raw\n        policy accept\n        udp dport { %s } notrack\n    }\n' "$PORTS_NFT" >&2
  exit 1
fi

TMP="$(mktemp)"
awk -v ports="$PORTS_NFT" '
  /^[[:space:]]*table inet mohaashield[[:space:]]*\{/ && !ins {
    print
    print "    chain raw_prerouting {"
    print "        type filter hook prerouting priority raw"
    print "        policy accept"
    print "        udp dport { " ports " } notrack"
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

nft -f "$NFT_CONF"               # atomic reload (empties sets as defined in the file)
if [ -x "$IMPORT_BANS" ]; then
  "$IMPORT_BANS"                 # repopulate permanent player/ddos ban sets
fi

echo "notrack added for { $PORTS_NFT }. Backup: $BACKUP"
echo "verify: sudo nft list chain inet mohaashield raw_prerouting"
