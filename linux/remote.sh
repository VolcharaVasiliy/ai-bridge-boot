#!/usr/bin/env bash
# ============================================================
#  remote.sh v2.2 — control wrapper for the owner's Windows PC.
#  Connection: ssh to Windows over the Tailscale SOCKS5 proxy.
#
#  Config (searched next to this script, then in ~/arena-bridge;
#  override via ARENA_BRIDGE_DIR or BRIDGE_HOST/BRIDGE_PORT/BRIDGE_SOCKS):
#    host.txt   - PC address in the tailnet (e.g. 100.x.y.z)
#    port.txt   - ssh port (22)
#    socks.txt  - tailscale socks5 (127.0.0.1:1055)
#    user.txt   - Windows username on the PC (e.g. your Windows login)
#
#  Modes:
#    ./remote.sh ping | info | cmd '...' | ps < file | psc '...'
#    ./remote.sh get 'C:/p/f' ./loc   |   ./remote.sh put ./loc 'C:/p/d/'
#    ./remote.sh elev '...' | elev - < file | elev-check | elev-out ID | elev-stop
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="${ARENA_BRIDGE_DIR:-$HOME/arena-bridge}"

cfg() {  # $1 = file name: look in script dir, then runtime dir
  local d
  for d in "$HERE" "$RUNTIME"; do
    if [ -s "$d/$1" ]; then head -n1 "$d/$1" | tr -d ' \r\n'; return; fi
  done
}

PORT="${BRIDGE_PORT:-$(cfg port.txt)}"
HOST="${BRIDGE_HOST:-$(cfg host.txt)}"
SOCKS="${BRIDGE_SOCKS:-$(cfg socks.txt)}"
RUSER="${BRIDGE_USER:-$(cfg user.txt)}"
KEY="${BRIDGE_KEY:-$HOME/.ssh/agent_ed25519}"

if [ -z "$PORT" ]; then echo "ERR: no port (port.txt / BRIDGE_PORT)" >&2; exit 3; fi
if [ -z "$RUSER" ]; then
  echo "ERR: no Windows username. Create user.txt:  echo '<username>' > $RUNTIME/user.txt  (or set BRIDGE_USER)" >&2
  exit 3
fi

SSH_BASE=( -i "$KEY" -p "$PORT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
  -o ConnectTimeout=15 -o ServerAliveInterval=30 -o BatchMode=yes
  -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-%r@%h:%p" -o ControlPersist=55 )
if [ -n "$SOCKS" ]; then
  SSH_BASE+=( -o "ProxyCommand=nc -X 5 -x $SOCKS %h %p" )
fi
SCP_BASE=( "${SSH_BASE[@]}" )
SCP_BASE[2]="-P"   # scp needs -P for the port

WIN_FWD="C:/Users/$RUSER/agent-bridge/elev"
WIN_BS="C:\\Users\\$RUSER\\agent-bridge\\elev"

rsh() { ssh "${SSH_BASE[@]}" "$RUSER@$HOST" "$@"; }

b64read() {  # remote file -> single-line base64 (empty on any error)
  rsh "powershell -NoProfile -Command \"try { [Convert]::ToBase64String([IO.File]::ReadAllBytes('$1')) } catch { }\"" 2>/dev/null \
    | tr -d '\r\n'
}
rd() { b64read "$1" | base64 -d 2>/dev/null || true; }

mode="${1:-}"; shift || true

case "$mode" in
  info)
    echo "host      : ${HOST:-(not set)}       [host.txt / BRIDGE_HOST]"
    echo "port      : $PORT                    [port.txt / BRIDGE_PORT]"
    echo "socks5    : ${SOCKS:-(none)}         [socks.txt / BRIDGE_SOCKS]"
    echo "windows us: $RUSER                   [user.txt / BRIDGE_USER]"
    echo "ssh key   : $KEY"
    echo "config dir: $HERE"
    [ "$HERE" != "$RUNTIME" ] && echo "runtime   : $RUNTIME"
    ;;

  ping)
    rsh 'echo PONG'
    ;;

  cmd)
    exec ssh "${SSH_BASE[@]}" "$RUSER@$HOST" "$*"
    ;;

  ps)
    exec ssh "${SSH_BASE[@]}" "$RUSER@$HOST" powershell -NoProfile -ExecutionPolicy Bypass -Command -
    ;;

  psc)
    _body="$*"
    _enc="$(printf '[Console]::OutputEncoding=[Text.Encoding]::UTF8\n$OutputEncoding=[Text.Encoding]::UTF8\n%s' "$_body" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
    exec ssh "${SSH_BASE[@]}" "$RUSER@$HOST" powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$_enc"
    ;;

  get)
    exec scp "${SCP_BASE[@]}" "$RUSER@$HOST:$1" "$2"
    ;;

  put)
    exec scp "${SCP_BASE[@]}" "$1" "$RUSER@$HOST:$2"
    ;;

  elev-check)
    hb="$(rd "$WIN_BS\\hb.txt" | tr -cd '0-9')"
    busy="$(rd "$WIN_BS\\busy.txt" | tr -d '\r\n')"
    if [ -z "$hb" ]; then
      echo "runner: NOT RUNNING (no heartbeat file)"
      exit 1
    fi
    age=$(( $(date +%s) - hb ))
    echo "runner: heartbeat ${age}s ago"
    if [ -n "$busy" ]; then echo "busy with: $busy"; else echo "idle"; fi
    if [ "$age" -gt 30 ]; then
      echo "WARN: heartbeat stale (long job or runner stopped)"
      exit 1
    fi
    ;;

  elev-stop)
    rsh "powershell -NoProfile -Command \"Set-Content -LiteralPath '$WIN_BS\\STOP' -Value stop -Force\"" \
      && echo "STOP file created - runner will pause after the current job"
    ;;

  elev-out)
    id="${1:-}"
    [ -z "$id" ] && { echo "usage: $0 elev-out <job-id>" >&2; exit 2; }
    rd "$WIN_BS\\out\\$id.ps1.out"
    d="$(rd "$WIN_BS\\out\\$id.ps1.done" | tr -d '\r\n')"
    echo ""
    echo "=== state: ${d:-RUNNING}"
    ;;

  elev)
    if [ "${1:-}" = "-" ] || [ -z "${1:-}" ]; then body="$(cat)"; else body="$*"; fi
    body="${body%$'\n'}"

    hb="$(rd "$WIN_BS\\hb.txt" | tr -cd '0-9')"
    if [ -z "$hb" ]; then
      echo "[elev] runner silent - trying to start the task..."
      rsh 'cmd /c schtasks /run /tn ArenaElev' >/dev/null 2>&1 || true
      sleep 4
      hb="$(rd "$WIN_BS\\hb.txt" | tr -cd '0-9')"
      if [ -z "$hb" ]; then
        echo "[elev] runner is NOT running. Ask the owner to run windows/enable-elev.ps1 (admin) once." >&2
        exit 4
      fi
    fi
    age=$(( $(date +%s) - hb ))
    [ "$age" -gt 30 ] && echo "[elev] note: heartbeat ${age}s old (long job or runner restarting)"

    id="j$(date -u +%Y%m%d-%H%M%S)-$$-$RANDOM"
    tmp="$(mktemp)"
    {
      printf '[Console]::OutputEncoding=[Text.Encoding]::UTF8\n'
      printf '$OutputEncoding=[Text.Encoding]::UTF8\n'
      printf '%s\n' "$body"
    } > "$tmp"

    scp "${SCP_BASE[@]}" -q "$tmp" "$RUSER@$HOST:$WIN_FWD/in/$id.ps1.tmp" \
      || { echo "[elev] upload failed" >&2; rm -f "$tmp"; exit 5; }
    rm -f "$tmp"
    rsh "cmd /c ren \"$WIN_BS\\in\\$id.ps1.tmp\" \"$id.ps1\"" >/dev/null 2>&1
    echo "[elev] job $id submitted"

    prev=0; waited=0; max="${ELEV_MAX:-1200}"
    outf="$(mktemp)"
    while [ "$waited" -lt "$max" ]; do
      resp="$(rsh "powershell -NoProfile -Command \"try { [Convert]::ToBase64String([IO.File]::ReadAllBytes('$WIN_BS\\out\\$id.ps1.out')) } catch { }; '===M==='; if (Test-Path '$WIN_BS\\out\\$id.ps1.done') { 'DONE' } else { 'RUN' }\"" 2>/dev/null || true)"

      b64="$(printf '%s\n' "$resp" | sed '/^===M===[[:space:]]*$/,$d' | tr -d '\r\n')"
      flag="$(printf '%s\n' "$resp" | awk 'f{print} /^===M===/{f=1}' | tr -d '\r\n ')"

      [ -n "$b64" ] && printf '%s' "$b64" | base64 -d > "$outf" 2>/dev/null || true
      len=$(wc -c < "$outf" 2>/dev/null || echo 0)
      if [ "$len" -gt "$prev" ]; then
        tail -c +$((prev+1)) "$outf"
        prev=$len
      fi

      if [ "$flag" = "DONE" ]; then
        d="$(rd "$WIN_BS\\out\\$id.ps1.done" | tr -d '\r\n')"
        echo ""
        echo "[elev] ${d:-DONE}"
        rm -f "$outf"
        exit 0
      fi

      waited=$((waited+1))
      sleep 1
    done
    echo ""
    echo "[elev] still running after ${max}s - job $id continues in background"
    echo "[elev] check later: $0 elev-out $id"
    rm -f "$outf"
    ;;

  *)
    echo "usage: $0 {info|ping|cmd|ps|psc|get|put|elev|elev-check|elev-out|elev-stop} ..." >&2
    exit 2
    ;;
esac
