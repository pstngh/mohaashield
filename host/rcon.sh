#!/usr/bin/env bash
# MOHAAShield — send an rcon command to the game server and print the reply, WITHOUT joining.
# rcon is a connectionless (OOB) command, so it works even when the server is full of fake
# players. Needs a non-empty `rconpassword` set in your server cfg. Pass the password via the
# RCON_PW env var (preferred — keeps it off your shell history) or --pw.
#
#   RCON_PW='secret' bash host/rcon.sh status              # list every client: slot, ping, IP
#   RCON_PW='secret' bash host/rcon.sh "clientkick 12"     # kick slot 12
#   RCON_PW='secret' bash host/rcon.sh --host 1.2.3.4 status
set -uo pipefail
HOST=127.0.0.1; PORT=12203; PW="${RCON_PW:-}"
while [ $# -gt 0 ]; do case "$1" in
  --pw)   PW="${2:?}";   shift ;;
  --host) HOST="${2:?}"; shift ;;
  --port) PORT="${2:?}"; shift ;;
  --) shift; break ;;
  -*) echo "unknown option: $1" >&2; exit 1 ;;
  *) break ;;
esac; shift; done
CMD="$*"
[ -n "$PW" ]  || { echo "no rcon password — set RCON_PW='...' or pass --pw" >&2; exit 1; }
[ -n "$CMD" ] || { echo "usage: RCON_PW='...' bash $0 [--host H --port P] <rcon command>" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "need python3 (sudo apt install -y python3)" >&2; exit 1; }

python3 - "$HOST" "$PORT" "$PW" "$CMD" <<'PY'
import socket, sys
host, port, pw, cmd = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(b'\xff\xff\xff\xff' + b'rcon ' + pw.encode() + b' ' + cmd.encode(), (host, port))
data = b''
try:
    while True:
        data += s.recv(65536)
except socket.timeout:
    pass
out = data.replace(b'\xff\xff\xff\xffprint\n', b'').replace(b'\xff\xff\xff\xff', b'')
out = out.decode('latin-1', 'replace')
print(out if out.strip() else
      '(no reply — wrong password, rconpassword not set, or the command produced no output)')
PY
