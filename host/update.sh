#!/usr/bin/env bash
# MOHAAShield local updater — pull the latest repo state and re-apply the host tooling.
# Safe to re-run anytime new changes are pushed.
#
#   bash host/update.sh          (run as your normal user; it sudo's for the privileged bits)
#
# The whole body is wrapped in { ... } with a trailing exit so bash parses the entire
# script into memory BEFORE running it. That makes the self-update safe even though
# `git pull` may rewrite this very file mid-run.
{
  set -euo pipefail
  cd "$(dirname "$0")/.."          # repo root

  echo "==> git pull"
  git pull --ff-only

  echo "==> re-apply flight recorder (install is idempotent; keeps your existing config)"
  sudo bash host/phase1/install.sh

  echo "==> restart service"
  sudo systemctl restart mohaashield-flightrecorder
  sudo systemctl status mohaashield-flightrecorder --no-pager || true

  echo "==> pcap dir"
  sudo ls -lh /var/lib/mohaashield/pcap || true

  echo "==> done"
  exit 0
}
