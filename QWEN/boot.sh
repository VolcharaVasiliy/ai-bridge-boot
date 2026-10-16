#!/usr/bin/env bash
# ============================================================
#  QWEN/boot.sh v1.0 — one-command bootstrap of the AI bridge
#  for the Qwen sandbox (Debian container, NO systemd, $HOME=/tmp
#  is volatile, background processes are killed between calls,
#  only /home/user persists across rebuilds).
#
#  Usage (agent side):
#    bash <(curl -fsSL https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/QWEN/boot.sh)
#
#  Idempotent — safe (and recommended) at the start of every session.
#  No secrets inside: auth key / private key live only in the
#  persistent dir (/home/user/arena-bridge), chmod 600.
# ============================================================
set -u
REPO="${AI_BRIDGE_REPO:-VolcharaVasiliy/ai-bridge-boot}"
REF="${AI_BRIDGE_REF:-main}"
BASE="https://raw.githubusercontent.com/$REPO/$REF"
PERSIST="${QWEN_PERSIST:-/home/user}"
# functional writability test ([ -w ] alone proved unreliable in this sandbox)
if ! { mkdir -p "$PERSIST" 2>/dev/null && touch "$PERSIST/.wtest" 2>/dev/null && rm -f "$PERSIST/.wtest"; }; then
  PERSIST="$HOME"
  echo "!! WARNING: /home/user not writable — falling back to volatile \$HOME ($PERSIST)."
  echo "!!          State will NOT survive a sandbox rebuild."
fi
BR="$PERSIST/qwen-bridge"
SPARE="${QWEN_SPARE:-/tmp/qwen-bridge-spare}"   # volatile twin of $BR
TS_VER="${TS_VER:-1.104.1}"
TS_HOSTNAME="${TS_HOSTNAME:-qwen-agent}"

# The snapshot of $PERSIST is LOSSY. Measured 2026-10-16 (Qwen sandbox, overlay
# mounted `volatile`): files written by ssh-keygen and by `curl -o X.tmp && mv
# X.tmp X` were gone at the next agent call, while files from `install` (75 MB
# binaries), `printf >` and a whole `git clone` survived. It is not
# deterministic — the same key survived one call boundary and not the next.
# So: every critical artifact is mirrored into $SPARE and PROVEN readable back
# from both copies before we move on.
persist() {  # $1 = path relative to $BR; returns 0 only if both copies verify
  local rel="$1" i
  mkdir -p "$SPARE/$(dirname "$rel")" 2>/dev/null
  for i in 1 2 3; do
    [ -s "$BR/$rel" ] && cp -f "$BR/$rel" "$SPARE/$rel" 2>/dev/null
    cmp -s "$BR/$rel" "$SPARE/$rel" 2>/dev/null && return 0
    [ -s "$SPARE/$rel" ] && cp -f "$SPARE/$rel" "$BR/$rel" 2>/dev/null
    sync 2>/dev/null
  done
  return 1
}

echo "== QWEN bridge boot (no-systemd sandbox) =="
echo "   repo:       $REPO @ $REF"
echo "   persistent: $BR"

SUDO=""
[ "$(id -u)" = "0" ] || SUDO="sudo"

# -- 0. packages (sandbox may be freshly rebuilt: no curl/ssh/nc/ip) --
pkgs=""
command -v curl >/dev/null 2>&1 || pkgs="$pkgs curl"
command -v ssh  >/dev/null 2>&1 || pkgs="$pkgs openssh-client"
command -v nc   >/dev/null 2>&1 || pkgs="$pkgs netcat-openbsd"
command -v ip   >/dev/null 2>&1 || pkgs="$pkgs iproute2"
if [ -n "$pkgs" ]; then
  echo "   installing:$pkgs"
  $SUDO apt-get update -qq >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq $pkgs >/dev/null 2>&1 \
    || echo "!! apt install failed — need root or sudo?"
fi
command -v curl >/dev/null 2>&1 || { echo "!! curl still missing, abort"; exit 1; }

mkdir -p "$BR/bin" "$BR/ts-backup" "$BR/ssh"
chmod 700 "$BR/ssh" 2>/dev/null

# -- 1. migrate volatile $HOME paths into the persistent dir, symlink back --
migrate() {  # $1 = volatile path (e.g. /tmp/.ssh), $2 = persistent target
  local src="$1" dst="$2" rsrc rdst
  rdst="$(readlink -f "$dst" 2>/dev/null)"
  rsrc="$(readlink -f "$src" 2>/dev/null)"
  [ -n "$rsrc" ] && [ "$rsrc" = "$rdst" ] && return 0   # already linked
  if [ -d "$src" ] && [ ! -L "$src" ]; then
    cp -a "$src/." "$dst/" 2>/dev/null || true
    rm -rf "$src"
  fi
  mkdir -p "$(dirname "$src")"
  ln -sfn "$dst" "$src"
}
migrate "$HOME/arena-bridge" "$BR"
migrate "$HOME/.ssh"         "$BR/ssh"

# legacy persistent layout (runtime was named arena-bridge before): pick files up
if [ -d "$PERSIST/arena-bridge" ] && [ "$PERSIST/arena-bridge" != "$BR" ]; then
  cp -an "$PERSIST/arena-bridge/." "$BR/" 2>/dev/null || true
fi

# -- 2. agent SSH key (own key, never a shared one) --
# RESTORE BEFORE GENERATING. A key lost from $BR used to mean a brand new
# pubkey, silently invalidating the line the owner already put into
# authorized_keys. The spare copy keeps the identity stable across snapshots.
if [ ! -s "$BR/ssh/agent_ed25519" ] && [ -s "$SPARE/ssh/agent_ed25519" ]; then
  mkdir -p "$BR/ssh" && chmod 700 "$BR/ssh" 2>/dev/null
  cp -f "$SPARE/ssh/agent_ed25519" "$BR/ssh/agent_ed25519"
  cp -f "$SPARE/ssh/agent_ed25519.pub" "$BR/ssh/agent_ed25519.pub" 2>/dev/null
  echo "   agent key restored from spare (pubkey unchanged)"
fi
if [ ! -s "$BR/ssh/agent_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$BR/ssh/agent_ed25519" -C "$TS_HOSTNAME" </dev/null
  echo "   generated new agent key"
fi
chmod 600 "$BR/ssh/agent_ed25519" 2>/dev/null
# .pub can be lost on its own; it is derivable from the private key
[ -s "$BR/ssh/agent_ed25519.pub" ] \
  || ssh-keygen -y -f "$BR/ssh/agent_ed25519" > "$BR/ssh/agent_ed25519.pub" 2>/dev/null
if persist ssh/agent_ed25519 && persist ssh/agent_ed25519.pub; then
  echo "   key mirrored to $SPARE and verified in both copies"
else
  echo "!! WARN: agent key is NOT stable — the owner may have to re-add the pubkey"
fi
if [ -s "$BR/.ts-authkey" ]; then chmod 600 "$BR/.ts-authkey"; persist .ts-authkey; fi

# -- 3. scripts: remote.sh is shared with linux/; session.sh is QWEN-specific --
# Prefer a local git clone over raw.githubusercontent: no CDN staleness (raw can
# serve a pre-push version for ~30 min) and it works with no network at all.
CLONE="${AI_BRIDGE_CLONE:-}"
if [ -z "$CLONE" ]; then
  for d in "$PERSIST/ai-bridge-boot" "$HOME/ai-bridge-boot" "$PERSIST"/*/ai-bridge-boot; do
    if [ -s "$d/linux/remote.sh" ] && [ -s "$d/QWEN/session.sh" ]; then CLONE="$d"; break; fi
  done
fi
[ -n "$CLONE" ] && echo "   script source: local clone $CLONE"

get_script() {  # $1 = name under $BR, $2 = path in clone, $3 = raw URL
  local name="$1" crel="$2" url="$3"
  if [ -n "$CLONE" ] && [ -s "$CLONE/$crel" ]; then
    cp -f "$CLONE/$crel" "$BR/$name" 2>/dev/null
  else
    curl -fsSL --retry 3 --retry-delay 2 -o "$BR/$name.tmp" "$url" \
      && mv "$BR/$name.tmp" "$BR/$name" || rm -f "$BR/$name.tmp"
  fi
  # last resort: whatever the spare saved on a previous run
  [ -s "$BR/$name" ] || { [ -s "$SPARE/$name" ] && cp -f "$SPARE/$name" "$BR/$name"; }
  chmod +x "$BR/$name" 2>/dev/null
  persist "$name"
}
fetch_ok=1
get_script remote.sh  linux/remote.sh "$BASE/linux/remote.sh" || fetch_ok=0
get_script session.sh QWEN/session.sh "$BASE/QWEN/session.sh" || fetch_ok=0
[ "$fetch_ok" = 1 ] || { echo "!! cannot fetch scripts and no local copies — abort"; exit 1; }

# -- 4. tailscale binaries: persistent copy + volatile install --
if [ ! -x "$BR/bin/tailscale" ] || [ ! -x "$BR/bin/tailscaled" ]; then
  echo "   downloading tailscale $TS_VER ..."
  ( cd /tmp && curl -sL -m 240 -o ts.tgz "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_amd64.tgz" \
    && tar xzf ts.tgz && D="tailscale_${TS_VER}_amd64" \
    && install -m755 "$D/tailscale"  "$BR/bin/tailscale" \
    && install -m755 "$D/tailscaled" "$BR/bin/tailscaled" ) \
    && echo "   binaries stored in $BR/bin" || echo "!! tailscale download failed"
fi
$SUDO install -m755 "$BR/bin/tailscale"  /usr/local/bin/tailscale  2>/dev/null
$SUDO install -m755 "$BR/bin/tailscaled" /usr/local/bin/tailscaled 2>/dev/null

# -- 5. bring the link up (daemon/state/login/peer) --
echo
QWEN_PERSIST="$PERSIST" QWEN_SPARE="$SPARE" TS_HOSTNAME="$TS_HOSTNAME" bash "$BR/session.sh"

# -- 6. report + next steps --
echo
echo "== owner one-liners (if not done yet) =="
PUB="$(cat "$BR/ssh/agent_ed25519.pub")"
echo "add this agent's key on the PC (PowerShell, one UAC click):"
echo
echo "&([scriptblock]::Create((irm https://raw.githubusercontent.com/$REPO/$REF/windows/add-key.ps1))) -Key '$PUB'"
echo
if [ ! -s "$BR/user.txt" ]; then
  echo "Windows login of the owner:  echo '<login>' > $BR/user.txt"
  echo "then check:  $BR/remote.sh ping   (expect PONG)"
else
  echo "== ping test =="
  timeout 90 "$BR/remote.sh" ping 2>&1 | tail -3
fi
echo
echo "note: the Tailscale auth key is one-time — after the first successful"
echo "      login the owner can revoke it (admin → Settings → Keys)."
echo "DONE. Work via: bash $BR/session.sh $BR/remote.sh <ping|cmd|psc|ps|get|put|runjob|elev> ..."
