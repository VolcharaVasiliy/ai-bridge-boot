#!/usr/bin/env bash
# ============================================================
#  remote.sh v2.3 — control wrapper for the owner's Windows PC.
#  Connection: ssh to Windows over the Tailscale SOCKS5 proxy.
#
#  Changes vs v2.2 (lessons from the first connect, 2026-10-13):
#   1. ping: 3 attempts + control-socket cleanup between them.
#      Fixes the first-contact race "Connection closed by UNKNOWN port 65535"
#      (DERP relay warm-up + stale cm-* socket).
#   2. Stale ControlMaster socket auto-cleanup before connects
#      (ssh -O check; dead socket files were breaking re-connects).
#   3. psc / ps / elev prepend $ProgressPreference='SilentlyContinue'
#      (kills the "#< CLIXML / Подготовка модулей" spam on stderr).
#   4. NEW mode: runjob <file.ps1> [timeout] — FILE-BASED job:
#      upload by scp, detached start via schtasks, log to file, poll,
#      fetch. Long jobs / long scripts survive relay hiccups —
#      a streamed `ps < script.ps1` dies mid-run with exit 255.
#      New mode runjob-out <id> fetches the log of a finished job.
#   5. ConnectTimeout 25: first contact over DERP relay can take >15 s.
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
#    ./remote.sh runjob file.ps1 [timeout_s]  |  runjob-out <job-id>
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
  -o ConnectTimeout=25 -o TCPKeepAlive=yes
  -o ServerAliveInterval=30 -o ServerAliveCountMax=4
  -o BatchMode=yes
  -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-%r@%h:%p" -o ControlPersist=55 )
if [ -n "$SOCKS" ]; then
  SSH_BASE+=( -o "ProxyCommand=nc -X 5 -x $SOCKS %h %p" )
fi
SCP_BASE=( "${SSH_BASE[@]}" )
SCP_BASE[2]="-P"   # scp needs -P for the port

WIN_FWD="C:/Users/$RUSER/agent-bridge/elev"
WIN_BS="C:\\\\Users\\\\$RUSER\\\\agent-bridge\\\\elev"
JOB_FWD="C:/Users/$RUSER/agent-bridge/jobs"
JOB_BS="C:\\\\Users\\\\$RUSER\\\\agent-bridge\\\\jobs"

# silence PS progress records inside remote sessions (CLIXML spam guard)
PS_PRE='\$ProgressPreference='"'"'SilentlyContinue'"'"''

rsh() { ssh "${SSH_BASE[@]}" "$RUSER@$HOST" "$@"; }

# --- control-master socket housekeeping --------------------
cm_file() { echo "$HOME/.ssh/cm-$RUSER@$HOST:$PORT"; }
cm_cleanup() {
  local f; f="$(cm_file)"
  [ -S "$f" ] || return 0
  ssh -O check -o "ControlPath=$f" "$RUSER@$HOST" 2>/dev/null && return 0
  rm -f "$f"   # dead socket -> drop it, next connect will recreate
}

# retry wrapper: N attempts, cm_cleanup between them (default 3, RETRY to override)
retry() {
  local n="${RETRY:-3}" i rc=0
  for i in $(seq 1 "$n"); do
    "$@" && return 0
    rc=$?
    if [ "$i" -lt "$n" ]; then
      echo "[retry] attempt $i failed (rc=$rc), cleaning socket and retrying..." >&2
      cm_cleanup; sleep 2
    fi
  done
  return "$rc"
}

b64read() {  # remote file -> single-line base64 (empty on any error)
  rsh "powershell -NoProfile -Command \\\"try { [Convert]::ToBase64String([IO.File]::ReadAllBytes('$1')) } catch { }\\\"" 2>/dev/null \
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
    retry rsh 'echo PONG'
    ;;

  cmd)
    cm_cleanup
    exec ssh "${SSH_BASE[@]}" "$RUSER@$HOST" "$@"
    ;;

  ps)   # short scripts only; long ones -> runjob (streams die mid-run)
    { printf '%s\n' "$PS_PRE"; cat; } | ssh "${SSH_BASE[@]}" "$RUSER@$HOST" powershell -NoProfile -ExecutionPolicy Bypass -Command -
    ;;

  psc)
    _body="$*"
    _enc="$(printf "$PS_PRE\n%s\n" "$_body" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
    cm_cleanup
    exec ssh "${SSH_BASE[@]}" "$RUSER@$HOST" powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$_enc"
    ;;

  get)
    cm_cleanup
    exec scp "${SCP_BASE[@]}" "$RUSER@$HOST:$1" "$2"
    ;;

  put)
    cm_cleanup
    exec scp "${SCP_BASE[@]}" "$1" "$RUSER@$HOST:$2"
    ;;

  # ---------- file-based detached jobs (relay-proof) ----------
  runjob)
    script="${1:-}"; max="${2:-600}"
    [ -f "$script" ] || { echo "usage: $0 runjob <file.ps1> [timeout_s=600]" >&2; exit 2; }
    id="j$(date -u +%Y%m%d-%H%M%S)-$$"
    wrap="$(mktemp --suffix=.cmd)"
    {
      echo '@echo off'
      echo 'chcp 65001 >nul'
      echo "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\$RUSER\\agent-bridge\\jobs\\$id.ps1\" 1> \"C:\\Users\\$RUSER\\agent-bridge\\jobs\\$id.out\" 2>&1"
      echo "echo done > \"C:\\Users\\$RUSER\\agent-bridge\\jobs\\$id.done\""
    } > "$wrap"

    # starter runs ON THE PC: computes the schedule time in the PC's own
    # locale (hardcoding MM/DD/YYYY fails on e.g. Russian Windows).
    # Schedule = now+1day, NOT now+2min: a near-future trigger fires during
    # the poll and runs the job a SECOND time; 1 day is safely past cleanup
    # (we delete the task when done) and past any sane timeout.
    starter="$(mktemp --suffix=.ps1)"
    cat > "$starter" <<EOF
\$t  = (Get-Date).AddDays(1)
\$sd = \$t.ToString('d')      # PC-locale short date (dd.MM.yyyy, MM/dd/yyyy, ...)
\$st = \$t.ToString('HH:mm')  # 24h time
schtasks /create /f /tn "ArenaJob-$id" /sc once /sd \$sd /st \$st /tr "C:\Users\\$RUSER\agent-bridge\jobs\\$id.wrap.cmd" | Out-Null
schtasks /run /tn "ArenaJob-$id" | Out-Null
"started $id"
EOF

    retry rsh "cmd /c mkdir \"C:\\Users\\$RUSER\\agent-bridge\\jobs\" 2>nul & exit /b 0" >/dev/null
    retry scp "${SCP_BASE[@]}" -q "$script" "$RUSER@$HOST:$JOB_FWD/$id.ps1" \
      || { echo "[runjob] upload failed" >&2; rm -f "$wrap" "$starter"; exit 5; }
    scp "${SCP_BASE[@]}" -q "$wrap"    "$RUSER@$HOST:$JOB_FWD/$id.wrap.cmd"
    scp "${SCP_BASE[@]}" -q "$starter" "$RUSER@$HOST:$JOB_FWD/$id.start.ps1"; rm -f "$wrap" "$starter"

    retry rsh "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\$RUSER\\agent-bridge\\jobs\\$id.start.ps1\"" >/dev/null \
      || { echo "[runjob] could not start task" >&2; exit 6; }
    echo "[runjob] job $id started"

    # NB poll via cmd quoting: nested powershell -Command quotes corrupt
    # across ssh->cmd->powershell, cmd parenthesized if exist is quote-safe.
    waited=0
    while [ "$waited" -lt "$max" ]; do
      st="$(rsh "cmd /c if exist \"C:\\Users\\$RUSER\\agent-bridge\\jobs\\$id.done\" (echo DONE) else (echo RUN)" 2>/dev/null | tr -d '\r\n')"
      [ "$st" = "DONE" ] && break
      sleep 3; waited=$((waited+3))
    done

    if [ "$st" != "DONE" ]; then
      echo "[runjob] still running after ${max}s - job continues on the PC as task ArenaJob-$id"
      echo "[runjob] fetch later: $0 runjob-out $id"
      echo "[runjob] cleanup task: $0 cmd 'schtasks /delete /f /tn ArenaJob-$id'  (one-time trigger may also fire once at its scheduled time tomorrow)"
      exit 0
    fi

    tmpo="$(mktemp)"
    scp "${SCP_BASE[@]}" -q "$RUSER@$HOST:$JOB_FWD/$id.out" "$tmpo" 2>/dev/null && cat "$tmpo"
    rm -f "$tmpo"
    rsh "cmd /c schtasks /delete /f /tn ArenaJob-$id >nul 2>nul & del /q \"C:\\Users\\$RUSER\\agent-bridge\\jobs\\$id.wrap.cmd\" \"C:\\Users\\$RUSER\\agent-bridge\\jobs\\$id.start.ps1\" 2>nul" >/dev/null 2>&1
    echo "[runjob] $id done (log kept on PC: $JOB_FWD/$id.out)"
    ;;

  runjob-out)
    id="${1:-}"
    [ -z "$id" ] && { echo "usage: $0 runjob-out <job-id>" >&2; exit 2; }
    st="$(rsh "cmd /c if exist \"C:\\Users\\$RUSER\\agent-bridge\\jobs\\$id.done\" (echo DONE) else (echo RUN)" 2>/dev/null | tr -d '\r\n')"
    tmpo="$(mktemp)"
    scp "${SCP_BASE[@]}" -q "$RUSER@$HOST:$JOB_FWD/$id.out" "$tmpo" 2>/dev/null && cat "$tmpo"
    rm -f "$tmpo"
    echo ""
    echo "=== state: ${st:-UNKNOWN (no such job?)}"
    ;;

  # ---------- audited elevation (unchanged protocol) ----------
  elev-check)
    hb="$(rd "$WIN_BS\\\\hb.txt" | tr -cd '0-9')"
    busy="$(rd "$WIN_BS\\\\busy.txt" | tr -d '\r\n')"
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
    rsh "powershell -NoProfile -Command \\\"Set-Content -LiteralPath '$WIN_BS\\\\STOP' -Value stop -Force\\\"" \
      && echo "STOP file created - runner will pause after the current job"
    ;;

  elev-out)
    id="${1:-}"
    [ -z "$id" ] && { echo "usage: $0 elev-out <job-id>" >&2; exit 2; }
    rd "$WIN_BS\\\\out\\\\$id.ps1.out"
    d="$(rd "$WIN_BS\\\\out\\\\$id.ps1.done" | tr -d '\r\n')"
    echo ""
    echo "=== state: ${d:-RUNNING}"
    ;;

  elev)
    if [ "${1:-}" = "-" ] || [ -z "${1:-}" ]; then body="$(cat)"; else body="$*"; fi
    body="${body%$'\n'}"

    hb="$(rd "$WIN_BS\\\\hb.txt" | tr -cd '0-9')"
    if [ -z "$hb" ]; then
      echo "[elev] runner silent - trying to start the task..."
      rsh 'cmd /c schtasks /run /tn ArenaElev' >/dev/null 2>&1 || true
      sleep 4
      hb="$(rd "$WIN_BS\\\\hb.txt" | tr -cd '0-9')"
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
      printf "$PS_PRE\n"
      printf '%s\n' "$body"
    } > "$tmp"

    scp "${SCP_BASE[@]}" -q "$tmp" "$RUSER@$HOST:$WIN_FWD/in/$id.ps1.tmp" \
      || { echo "[elev] upload failed" >&2; rm -f "$tmp"; exit 5; }
    rm -f "$tmp"
    rsh "cmd /c ren \\\"$WIN_BS\\\\in\\\\$id.ps1.tmp\\\" \\\"$id.ps1\\\"" >/dev/null 2>&1
    echo "[elev] job $id submitted"

    prev=0; waited=0; max="${ELEV_MAX:-1200}"
    outf="$(mktemp)"
    while [ "$waited" -lt "$max" ]; do
      resp="$(rsh "powershell -NoProfile -Command \\\"try { [Convert]::ToBase64String([IO.File]::ReadAllBytes('$WIN_BS\\\\out\\\\$id.ps1.out')) } catch { }; '===M==='; if (Test-Path '$WIN_BS\\\\out\\\\$id.ps1.done') { 'DONE' } else { 'RUN' }\\\"" 2>/dev/null || true)"

      b64="$(printf '%s\n' "$resp" | sed '/^===M===[[:space:]]*$/,$d' | tr -d '\r\n')"
      flag="$(printf '%s\n' "$resp" | awk 'f{print} /^===M===/{f=1}' | tr -d '\r\n ')"

      [ -n "$b64" ] && printf '%s' "$b64" | base64 -d > "$outf" 2>/dev/null || true
      len=$(wc -c < "$outf" 2>/dev/null || echo 0)
      if [ "$len" -gt "$prev" ]; then
        tail -c +$((prev+1)) "$outf"
        prev=$len
      fi

      if [ "$flag" = "DONE" ]; then
        d="$(rd "$WIN_BS\\\\out\\\\$id.ps1.done" | tr -d '\r\n')"
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
    echo "usage: $0 {info|ping|cmd|ps|psc|get|put|runjob|runjob-out|elev|elev-check|elev-out|elev-stop} ..." >&2
    exit 2
    ;;
esac
