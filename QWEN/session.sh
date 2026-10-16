#!/usr/bin/env bash
# ============================================================
#  QWEN/session.sh v1.0 — link resurrection for sandboxes that
#  kill background processes between calls and have no systemd.
#
#  Usage:  bash session.sh [command...]     (no args -> ts status)
#          Typical: bash session.sh "$HOME/arena-bridge/remote.sh" ping
#
#  Does:   binaries in place? -> daemon alive? (else pkill stale,
#          restore state from backup, setsid start) -> login via
#          saved auth key if logged out -> discover Windows peer
#          (+ warm-up when the peer changed) -> run command ->
#          backup node state into the persistent dir.
#
#  Persistent dir: /home/user/arena-bridge (override QWEN_PERSIST).
#  $HOME (/tmp) is volatile in this sandbox — never store state there.
# ============================================================
set -u
PERSIST="${QWEN_PERSIST:-/home/user}"
[ -w "$PERSIST" ] || PERSIST="$HOME"
BR="$PERSIST/qwen-bridge"

SOCK=/tmp/tailscaled.sock
STATE=/var/lib/tailscale/tailscaled.state
TS_BIN=/usr/local/bin/tailscale
TSD_BIN=/usr/local/bin/tailscaled
AUTHKEY="$BR/.ts-authkey"
TS_HOSTNAME="${TS_HOSTNAME:-qwen-agent}"
SOCKS_PORT="${TS_SOCKS_PORT:-1055}"

backup_state() {
  [ -s "$STATE" ] && mkdir -p "$BR/ts-backup" \
    && cp "$STATE" "$BR/ts-backup/tailscaled.state" 2>/dev/null
}
trap backup_state EXIT

# -- 0. binaries (volatile /usr/local/bin may be wiped after rebuild) --
if [ ! -x "$TS_BIN" ] || [ ! -x "$TSD_BIN" ]; then
  if [ -x "$BR/bin/tailscale" ] && [ -x "$BR/bin/tailscaled" ]; then
    install -m755 "$BR/bin/tailscale"  "$TS_BIN"  2>/dev/null
    install -m755 "$BR/bin/tailscaled" "$TSD_BIN" 2>/dev/null
  fi
fi
[ -x "$TSD_BIN" ] || { echo "[session] ERR: no tailscaled — run QWEN/boot.sh first" >&2; exit 1; }
TS="$TS_BIN --socket=$SOCK"

daemon_ok() {
  [ -S "$SOCK" ] || return 1
  # liveness via localapi: unlike `tailscale status`, works logged-in AND logged-out.
  # NB: the Host header must be local-tailscaled.sock, else tailscaled answers 403.
  if command -v curl >/dev/null 2>&1; then
    timeout 5 curl -sf --unix-socket "$SOCK" http://local-tailscaled.sock/localapi/v0/status >/dev/null 2>&1
  else
    $TS status >/dev/null 2>&1
  fi
}

# -- 1. daemon --
if ! daemon_ok; then
  # stale/half-dead daemon holds the SOCKS port -> always clean up first
  pkill -x tailscaled 2>/dev/null; sleep 1; rm -f "$SOCK"
  # ssh ControlMaster sockets are proxied through tailscaled's SOCKS: they are
  # dead after a daemon restart, but `-O check` still trusts them (symptom:
  # "Connection closed by UNKNOWN port 65535"). Drop them all.
  rm -f "$BR"/ssh/cm-* "$HOME"/.ssh/cm-* 2>/dev/null
  mkdir -p "$(dirname "$STATE")"
  if [ ! -s "$STATE" ] && [ -s "$BR/ts-backup/tailscaled.state" ]; then
    cp "$BR/ts-backup/tailscaled.state" "$STATE" && echo "[session] state restored from backup"
  fi
  # dummy0: in some sandboxes tailscaled sees only link-local and hangs on login
  if command -v ip >/dev/null 2>&1; then
    ip link add dummy0 type dummy 2>/dev/null
    ip link set dummy0 up 2>/dev/null
    ip addr show dev dummy0 2>/dev/null | grep -q 192.0.2.1 || ip addr add 192.0.2.1/32 dev dummy0 2>/dev/null
  fi
  setsid "$TSD_BIN" --tun=userspace-networking --socks5-server=127.0.0.1:$SOCKS_PORT \
    --state="$STATE" --socket="$SOCK" </dev/null >>"$BR/tailscaled.log" 2>&1 &
  for _ in $(seq 1 25); do daemon_ok && break; sleep 1; done
  if ! daemon_ok; then
    echo "[session] ERR: tailscaled did not start; last log lines:" >&2
    tail -5 "$BR/tailscaled.log" 2>/dev/null >&2
    exit 1
  fi
fi

# -- 2. login (only when logged out; state backup makes re-auth rare) --
if $TS status 2>&1 | grep -qi 'logged out'; then
  if [ -s "$AUTHKEY" ]; then
    echo "[session] logging in with saved auth key ..."
    if timeout 60 $TS up --authkey="$(cat "$AUTHKEY")" --hostname="$TS_HOSTNAME" --accept-dns=false >/dev/null 2>&1; then
      echo "[session] logged in"
    else
      echo "[session] LOGIN FAILED (key revoked/expired?) — ask the owner for a new tskey-auth-..." >&2
    fi
  else
    echo "[session] *** LOGIN REQUIRED *** no auth key at $AUTHKEY" >&2
    echo "[session] ask the owner for a Tailscale auth key, then:" >&2
    echo "[session]   printf '%s' '<KEY>' > $AUTHKEY && chmod 600 $AUTHKEY" >&2
  fi
fi

# -- 3. discover the Windows peer --
peer_json() {
  python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
best=None
for k,v in (d.get("Peer") or {}).items():
    if v.get("OS")=="windows":
        ips=v.get("TailscaleIPs") or []
        if ips:
            if v.get("Online"): print(ips[0]); sys.exit(0)
            best=best or ips[0]
if best: print(best)
' 2>/dev/null
}
peer_awk() { $TS status 2>/dev/null | awk '/windows/ {print $1; exit}'; }
PEER="$($TS status --json 2>/dev/null | peer_json)"
[ -n "$PEER" ] || PEER="$(peer_awk)"
if [ -n "$PEER" ]; then
  OLD="$(head -n1 "$BR/host.txt" 2>/dev/null | tr -d ' \r\n')"
  echo "$PEER" > "$BR/host.txt"; echo 22 > "$BR/port.txt"; echo "127.0.0.1:$SOCKS_PORT" > "$BR/socks.txt"
  if [ "$OLD" != "$PEER" ]; then
    # warm-up: cold DERP relay drops the first probes (see repo postmortem)
    echo "[session] peer $PEER — warming up link ..."
    timeout 15 $TS ping -c 1 "$PEER" >/dev/null 2>&1
    for _ in 1 2 3; do
      timeout 12 nc -X 5 -x 127.0.0.1:$SOCKS_PORT -z -w 6 "$PEER" 22 2>/dev/null && break
      sleep 3
    done
  fi
fi

# -- 4. hot spare of critical files --
# /home/user once lost a freshly bulk-migrated dir between calls (readdir saw
# nothing, lookups flickered — volatile overlay/virtiofs race). Small probes
# survive fine; still, keep a volatile spare and self-heal from it.
SPARE=/tmp/qwen-bridge-spare
mkdir -p "$SPARE/ssh" "$SPARE/ts-backup"
CRIT="ssh/agent_ed25519 ssh/agent_ed25519.pub ssh/known_hosts ts-backup/tailscaled.state host.txt port.txt socks.txt user.txt .ts-authkey remote.sh session.sh"
for f in $CRIT; do
  [ -e "$BR/$f" ] && cp -f "$BR/$f" "$SPARE/$f" 2>/dev/null
done
for f in $CRIT; do
  if [ ! -e "$BR/$f" ] && [ -e "$SPARE/$f" ]; then
    mkdir -p "$(dirname "$BR/$f")" && cp -f "$SPARE/$f" "$BR/$f" \
      && echo "[session] restored $f from spare"
  fi
done
chmod 600 "$BR/ssh/agent_ed25519" "$BR/.ts-authkey" 2>/dev/null

backup_state
if [ $# -gt 0 ]; then exec "$@"; fi
$TS status 2>&1 | head -8
