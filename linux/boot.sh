#!/usr/bin/env bash
# ============================================================
#  linux/boot.sh — AI-BRIDGE: one-command bootstrap (agent side)
#
#  Usage (Debian/Ubuntu sandbox with sudo):
#    bash <(curl -fsSL https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/linux/boot.sh)
#
#  What it does:
#    1. downloads ts-boot.sh + remote.sh into ~/arena-bridge (runtime dir)
#    2. runs ts-boot.sh — full self-healing setup of the Tailscale link
#    3. prints what to do next (auth key from the owner, then ./remote.sh ping)
#
#  No secrets inside. Auth keys / SSH keys are created or received at runtime.
# ============================================================
set -u

REPO="${AI_BRIDGE_REPO:-VolcharaVasiliy/ai-bridge-boot}"
REF="${AI_BRIDGE_REF:-main}"
BASE="${AI_BRIDGE_BASE:-https://raw.githubusercontent.com/$REPO/$REF}"
RUNTIME="${ARENA_BRIDGE_DIR:-$HOME/arena-bridge}"

echo "== AI-BRIDGE linux boot =="
echo "   repo:    $REPO @ $REF"
echo "   runtime: $RUNTIME"
mkdir -p "$RUNTIME" "$RUNTIME/ts-backup"

ok=1
for f in ts-boot.sh remote.sh; do
  if curl -fsSL --retry 3 --retry-delay 2 -o "$RUNTIME/$f" "$BASE/linux/$f"; then
    chmod +x "$RUNTIME/$f"
    echo "  [ok]   $f -> $RUNTIME/$f"
  else
    echo "  [fail] $f (не скачался)"
    ok=0
  fi
done
if [ "$ok" -ne 1 ]; then
  echo "Ошибка загрузки скриптов. Проверь доступ к raw.githubusercontent.com."
  exit 1
fi

echo
echo "== запускаю ts-boot.sh (самовосстановление канала) =="
bash "$RUNTIME/ts-boot.sh"

echo
echo "== что дальше =="
if [ ! -s "$RUNTIME/user.txt" ]; then
  echo "  1) запиши Windows-логин владельца:  echo '<логин>' > $RUNTIME/user.txt"
fi
if [ ! -s "$RUNTIME/.ts-authkey" ] && ! sudo tailscale --socket=/tmp/tailscaled.sock status 2>/dev/null | grep -qi 'logged in'; then
  echo "  2) если вывелось 'НУЖЕН ЛОГИН' — попроси у владельца Tailscale auth key"
  echo "     (tskey-auth-...), сохрани в $RUNTIME/.ts-authkey (chmod 600) и запусти ts-boot.sh снова"
fi
echo "  3) проверка связи:  $RUNTIME/remote.sh ping   (ждём PONG)"
