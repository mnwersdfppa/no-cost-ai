#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/canonical-config-agent.py"
ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
BIN="$ROOT/bin"
RUNTIME="$ROOT/runtime"
SECRETS="$ROOT/secrets"
ENV_FILE="$SECRETS/pi-canonical-config.env"
UNIT_DIR="$HOME/.config/systemd/user"
AGENT="$BIN/openclaw-canonical-config"

for command in python3 systemctl install; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "BLOCKED=MISSING_COMMAND:$command"
    exit 20
  }
done
[[ -r "$SOURCE" ]] || { echo "BLOCKED=AGENT_SOURCE_MISSING:$SOURCE"; exit 21; }

mkdir -p "$BIN" "$RUNTIME" "$SECRETS" "$UNIT_DIR"
chmod 700 "$ROOT" "$BIN" "$RUNTIME" "$SECRETS" "$UNIT_DIR" 2>/dev/null || true
install -m 700 "$SOURCE" "$AGENT"

if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<EOF
SUPABASE_URL=https://dpllasnpfskyyyzebyal.supabase.co
PI_ACCESS_TOKEN=
PI_REFRESH_TOKEN=
OPENCLAW_RUNTIME_DIR=$RUNTIME
CANONICAL_CONFIG_PATH=$RUNTIME/canonical-client.json
CANONICAL_CLIENT_ENV_PATH=$RUNTIME/supabase-client.env
SESSION_ENV_PATH=$ENV_FILE
EOF
  chmod 600 "$ENV_FILE"
  echo "RESULT=SESSION_ENV_CREATED"
  echo "ENV_FILE=$ENV_FILE"
  echo "NEXT=insert a current Pi access token and optional refresh token, then rerun"
  exit 22
fi
chmod 600 "$ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
if [[ -z "${PI_ACCESS_TOKEN:-}" && -z "${PI_REFRESH_TOKEN:-}" ]]; then
  echo "BLOCKED=PI_SESSION_MATERIAL_MISSING"
  echo "ENV_FILE=$ENV_FILE"
  exit 23
fi

cat > "$UNIT_DIR/openclaw-canonical-config.service" <<EOF
[Unit]
Description=Refresh canonical Supabase and Vercel client configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/env python3 $AGENT
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$RUNTIME $ENV_FILE
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6
SystemCallArchitectures=native
TimeoutStartSec=90
EOF

cat > "$UNIT_DIR/openclaw-canonical-config.timer" <<'EOF'
[Unit]
Description=Refresh canonical client configuration every six hours

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
RandomizedDelaySec=5min
Persistent=true
Unit=openclaw-canonical-config.service

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now openclaw-canonical-config.timer
set +e
systemctl --user start openclaw-canonical-config.service
STATUS=$?
set -e
if [[ $STATUS -eq 0 ]]; then
  echo "RESULT=CANONICAL_CONFIG_TIMER_READY"
else
  echo "RESULT=TIMER_READY_INITIAL_REFRESH_BLOCKED"
  echo "NEXT=check current Pi access/refresh token without printing it"
fi
systemctl --user status openclaw-canonical-config.timer --no-pager || true

echo "AGENT=$AGENT"
echo "ENV_FILE=$ENV_FILE"
echo "CONFIG_PATH=$RUNTIME/canonical-client.json"
echo "CLIENT_ENV_PATH=$RUNTIME/supabase-client.env"
echo "KEY_VALUES_PRINTED=NO"
