#!/usr/bin/env bash
# install.sh — install the agent-ops key proxy. Run by the USER with sudo; agents never run it.
#   sudo bash install.sh [--port N]            install or update (idempotent; keeps the store's keys)
#   sudo bash install.sh --uninstall [--purge]  remove service + code; --purge also deletes store, logs, user
# macOS only: hidden user _agentops_keyproxy + LaunchDaemon com.agent-ops.keyproxy. Prints no secret values.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo bash $0 $*"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin    # never run a user-writable binary as root
unset PYTHONPATH PYTHONHOME CURL_HOME XDG_CONFIG_HOME

[ "$(uname -s)" = Darwin ] || { echo "key proxy install is macOS only (found $(uname -s)); skip this add-on"; exit 1; }

PORT=8787 UNINSTALL=0 PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown argument $1"; exit 2 ;;
  esac
done
case "$PORT" in ''|*[!0-9]*) echo "--port must be a number"; exit 2 ;; esac

SRC="$(cd "$(dirname "$0")" && pwd)"
DATA=/var/lib/agent-ops-keyproxy
LOGS=/var/log/agent-ops-keyproxy
FILES="keyproxy.py keyproxy-set.py keyproxy-health install.sh"
SVC_USER=_agentops_keyproxy
APP="/Library/Application Support/agent-ops-keyproxy"
LABEL=com.agent-ops.keyproxy
UNIT="/Library/LaunchDaemons/$LABEL.plist"
PY=/Library/Developer/CommandLineTools/usr/bin/python3   # root-owned; /usr/bin/python3 is a shim
[ -x "$PY" ] || PY=/usr/bin/python3

if [ "$UNINSTALL" = 1 ]; then
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  rm -f "$UNIT"
  rm -rf "$APP"
  if [ "$PURGE" = 1 ]; then
    rm -rf "$DATA" "$LOGS"
    dscl . -delete "/Users/$SVC_USER" 2>/dev/null || true
    dscl . -delete "/Groups/$SVC_USER" 2>/dev/null || true
    echo "keyproxy removed, store + logs + service user purged"
  else
    echo "keyproxy removed; store kept in $DATA (re-run with --uninstall --purge to delete it)"
  fi
  exit 0
fi

[ -x "$PY" ] || { echo "need python3 at $PY"; exit 1; }

# ---- service user ----
if ! dscl . -read "/Users/$SVC_USER" >/dev/null 2>&1; then
  ID=""
  for i in $(seq 400 499); do
    if ! dscl . -list /Users UniqueID | awk -v id="$i" '$2==id{f=1} END{exit !f}' &&
       ! dscl . -list /Groups PrimaryGroupID | awk -v id="$i" '$2==id{f=1} END{exit !f}'; then ID=$i; break; fi
  done
  [ -n "$ID" ] || { echo "no free id in 400-499"; exit 1; }
  dscl . -create "/Groups/$SVC_USER"; dscl . -create "/Groups/$SVC_USER" PrimaryGroupID "$ID"
  dscl . -create "/Users/$SVC_USER"
  dscl . -create "/Users/$SVC_USER" UniqueID "$ID"
  dscl . -create "/Users/$SVC_USER" PrimaryGroupID "$ID"
  dscl . -create "/Users/$SVC_USER" UserShell /usr/bin/false
  dscl . -create "/Users/$SVC_USER" NFSHomeDirectory /var/empty
  dscl . -create "/Users/$SVC_USER" RealName "agent-ops key proxy"
  dscl . -create "/Users/$SVC_USER" IsHidden 1
  dscl . -create "/Users/$SVC_USER" Password '*'
  echo "created service user $SVC_USER ($ID)"
fi

# ---- root-owned code: no agent can change what the daemon does ----
install -d -o root -g wheel -m 755 "$APP"
if [ "$SRC" != "$APP" ]; then
  for f in $FILES; do
    case "$f" in *.py) m=644 ;; *) m=755 ;; esac
    install -o root -g wheel -m "$m" "$SRC/$f" "$APP/$f"
  done
fi

# ---- store (only the service user can enter) + audit log (readable, holds no secrets) ----
install -d -o "$SVC_USER" -g "$SVC_USER" -m 700 "$DATA"
[ -f "$DATA/store.json" ] || echo '{"routes": {}}' > "$DATA/store.json"
chown "$SVC_USER:$SVC_USER" "$DATA/store.json"; chmod 600 "$DATA/store.json"
install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$LOGS"
touch "$LOGS/audit.log" "$LOGS/daemon.err"
chown "$SVC_USER:$SVC_USER" "$LOGS/audit.log" "$LOGS/daemon.err"; chmod 644 "$LOGS/audit.log" "$LOGS/daemon.err"

# ---- service ----
launchctl bootout "system/$LABEL" 2>/dev/null || true
cat > "$UNIT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>UserName</key><string>$SVC_USER</string>
  <key>GroupName</key><string>$SVC_USER</string>
  <key>ProgramArguments</key>
  <array><string>$PY</string><string>-I</string><string>$APP/keyproxy.py</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>KEYPROXY_STORE</key><string>$DATA/store.json</string>
    <key>KEYPROXY_PORT</key><string>$PORT</string>
    <key>KEYPROXY_LOG_DIR</key><string>$LOGS</string>
    <key>PYTHONDONTWRITEBYTECODE</key><string>1</string>
    <key>HOME</key><string>/var/empty</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$LOGS/daemon.err</string>
  <key>StandardOutPath</key><string>$LOGS/daemon.err</string>
</dict>
</plist>
EOF
chown root:wheel "$UNIT"; chmod 644 "$UNIT"
sleep 1
launchctl bootstrap system "$UNIT"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -q -fsS -m 2 "http://127.0.0.1:$PORT/_health" >/dev/null 2>&1 && break
  sleep 1
done
echo "health: $(curl -q -fsS -m 2 "http://127.0.0.1:$PORT/_health" || echo "DOWN — see $LOGS/daemon.err")"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  echo "store readable by $SUDO_USER? $(sudo -u "$SUDO_USER" test -r "$DATA/store.json" && echo 'YES - BAD' || echo 'no, good')"
fi
echo "add a key:  sudo $PY -I \"$APP/keyproxy-set.py\" <route> --new --upstream https://<api host> --auth bearer"
echo "health:     \"$APP/keyproxy-health\" $PORT      config.env: COS_VAULT_PORT=$PORT"
