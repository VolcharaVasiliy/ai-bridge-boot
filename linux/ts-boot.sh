#!/bin/bash
# ============================================================
#  ts-boot.sh v4 — SELF-HEALING bootstrap of the AI <-> PC link.
#  Idempotent: safe to run at the start of every session.
#
#   1) permissions (reset after sandbox rebuild)
#   2) tailscale/netcat binaries (re-download if wiped)
#   3) systemd units (recreate if wiped)
#   4) network: dummy0 (else tailscaled thinks "no network" and login hangs)
#   5) node state from backup; login via ~/arena-bridge/.ts-authkey
#   6) auto-discover the Windows peer in the tailnet -> host/port/socks files
#   7) ping test; 8) state backup
#
#  Runtime dir: ~/arena-bridge (override: ARENA_BRIDGE_DIR)
# ============================================================
set -u
RUNTIME="${ARENA_BRIDGE_DIR:-$HOME/arena-bridge}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OWNER="$(id -un):$(id -gn)"

TS=/usr/local/bin/tailscale
TSD=/usr/local/bin/tailscaled
SOCK=/tmp/tailscaled.sock
STATE=/var/lib/tailscale/tailscaled.state
BACKUP="$RUNTIME/ts-backup/tailscaled.state"
AUTHKEY="$RUNTIME/.ts-authkey"
VER="${TS_VER:-1.104.1}"
TS_HOSTNAME="${TS_HOSTNAME:-arena-agent}"

mkdir -p "$RUNTIME" "$RUNTIME/ts-backup"

echo "== 0. permissions =="
chmod 600 "$HOME/.ssh/agent_ed25519" 2>/dev/null && echo "ssh key -> 600" || true
[ -f "$AUTHKEY" ] && chmod 600 "$AUTHKEY" && echo "auth-key -> 600" || true
chmod +x "$HERE/remote.sh" "$RUNTIME/remote.sh" 2>/dev/null && echo "scripts -> +x" || true
[ -x "$RUNTIME/remote.sh" ] || cp -f "$HERE/remote.sh" "$RUNTIME/remote.sh" 2>/dev/null || true

echo "== 1. binaries =="
if [ ! -x "$TS" ] || [ ! -x "$TSD" ]; then
  echo "downloading tailscale $VER ..."
  ( cd /tmp && curl -sL -m 150 -o ts.tgz "https://pkgs.tailscale.com/stable/tailscale_${VER}_amd64.tgz" \
    && tar xzf ts.tgz && D=$(ls -d tailscale_${VER}_amd64 | head -1) \
    && sudo install -m 755 "$D/tailscale" "$TS" && sudo install -m 755 "$D/tailscaled" "$TSD" ) \
    && echo "binaries restored" || echo "!! binary download failed"
else
  echo "tailscale present"
fi
command -v nc >/dev/null 2>&1 || { sudo apt-get install -y -qq netcat-openbsd >/dev/null 2>&1 && echo "netcat installed"; }

echo "== 2. systemd units =="
if [ ! -f /etc/systemd/system/tailscaled.service ]; then
  sudo tee /etc/systemd/system/tailscaled.service >/dev/null <<EOF
[Unit]
Description=Tailscale node agent (userspace, SOCKS5 :1055)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c '/bin/mkdir -p /var/lib/tailscale; ip link show dummy0 >/dev/null 2>&1 || ip link add dummy0 type dummy; ip link set dummy0 up; ip addr show dev dummy0 | grep -q 192.0.2.1 || ip addr add 192.0.2.1/32 dev dummy0'
ExecStart=/usr/local/bin/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 --state=/var/lib/tailscale/tailscaled.state --socket=/tmp/tailscaled.sock
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  echo "unit tailscaled.service recreated"
fi
if [ ! -f /etc/systemd/system/tailscale-backup.service ]; then
  sudo tee /etc/systemd/system/tailscale-backup.service >/dev/null <<EOF
[Unit]
Description=Copy tailscale state into the workspace backup
[Service]
Type=oneshot
ExecStart=/bin/sh -c '/bin/cp /var/lib/tailscale/tailscaled.state $RUNTIME/ts-backup/tailscaled.state && /bin/chown $OWNER $RUNTIME/ts-backup/tailscaled.state'
EOF
  sudo tee /etc/systemd/system/tailscale-backup.timer >/dev/null <<EOF
[Unit]
Description=Periodic tailscale state backup
[Timer]
OnCalendar=*:0/10
Unit=tailscale-backup.service
[Install]
WantedBy=timers.target
EOF
  echo "backup timer recreated"
fi

echo "== 3. network (dummy0) =="
ip link show dummy0 >/dev/null 2>&1 || sudo ip link add dummy0 type dummy
sudo ip link set dummy0 up
ip addr show dev dummy0 | grep -q "192.0.2.1" || sudo ip addr add 192.0.2.1/32 dev dummy0
echo "dummy0 ok"

echo "== 4. state =="
sudo mkdir -p /var/lib/tailscale
if [ ! -s "$STATE" ] && [ -s "$BACKUP" ]; then
  sudo cp "$BACKUP" "$STATE" && echo "restored from backup"
elif [ -s "$STATE" ]; then
  echo "state present"
else
  echo "no state (login will be required)"
fi

echo "== 5. daemon =="
sudo systemctl daemon-reload
sudo systemctl enable --now tailscaled.service tailscale-backup.timer >/dev/null 2>&1
systemctl is-active --quiet tailscaled.service || { sudo systemctl restart tailscaled.service; sleep 3; }
echo "tailscaled: $(systemctl is-active tailscaled.service)"

echo "== 6. login =="
if sudo $TS --socket="$SOCK" status 2>&1 | grep -qi "logged out"; then
  if [ -s "$AUTHKEY" ]; then
    echo "logging in with saved auth-key ..."
    sudo timeout 60 $TS --socket="$SOCK" up --authkey="$(cat "$AUTHKEY")" --hostname="$TS_HOSTNAME" --accept-dns=false 2>&1 | head -3
  else
    echo ""
    echo "*** LOGIN REQUIRED ***"
    echo "Ask the owner for a Tailscale auth key (tskey-auth-...), then:"
    echo "  mkdir -p $RUNTIME && printf '%s' '<KEY>' > $AUTHKEY && chmod 600 $AUTHKEY"
    echo "and run this script again."
    echo "(or with the owner present: sudo $TS --socket=$SOCK up --hostname=$TS_HOSTNAME --accept-dns=false gives a login URL)"
  fi
fi
sudo $TS --socket="$SOCK" status 2>&1 | head -8

echo "== 7. find Windows peer in tailnet =="
PEER="$(sudo $TS --socket="$SOCK" status --json 2>/dev/null | python3 -c '
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
' 2>/dev/null)"
if [ -n "$PEER" ]; then
  echo "$PEER" > "$RUNTIME/host.txt"
  echo "22" > "$RUNTIME/port.txt"
  echo "127.0.0.1:1055" > "$RUNTIME/socks.txt"
  echo "PC found: $PEER (written to host.txt/port.txt/socks.txt)"
else
  echo "no Windows peer found - check that Tailscale is online on the PC"
fi
if [ ! -s "$RUNTIME/user.txt" ]; then
  echo "NOTE: set the Windows username:  echo '<username>' > $RUNTIME/user.txt"
fi

echo "== 8. ping =="
if [ -x "$RUNTIME/remote.sh" ] && [ -s "$RUNTIME/host.txt" ] && [ -s "$RUNTIME/user.txt" ]; then
  timeout 40 "$RUNTIME/remote.sh" ping 2>&1 | head -3 || true
fi

echo "== 9. backup state =="
sudo cp "$STATE" "$BACKUP" 2>/dev/null && sudo chown "$OWNER" "$BACKUP" && echo "updated" || echo "(not critical)"

echo ""
echo "DONE. Work with: $RUNTIME/remote.sh ping|cmd|psc|ps|get|put|elev ..."
