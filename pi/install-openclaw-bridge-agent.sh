#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/openclaw-bridge-agent.py"
ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
BIN_DIR="$ROOT/bin"
RUNTIME_DIR="$ROOT/runtime"
SECRETS_DIR="$ROOT/secrets"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$SECRETS_DIR/pi-work-queue.env}"
UNIT_DIR="$HOME/.config/systemd/user"
AGENT="$BIN_DIR/openclaw-bridge-agent"

for command in python3 systemctl install; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "BLOCKED=MISSING_COMMAND:$command" >&2
    exit 20
  }
done

[[ -r "$SOURCE" ]] || {
  echo "BLOCKED=AGENT_SOURCE_MISSING:$SOURCE" >&2
  exit 21
}

mkdir -p "$ROOT" "$BIN_DIR" "$RUNTIME_DIR" "$SECRETS_DIR" "$UNIT_DIR"
chmod 700 "$ROOT" "$BIN_DIR" "$RUNTIME_DIR" "$SECRETS_DIR"
install -m 700 "$SOURCE" "$AGENT"

if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<EOF
SUPABASE_URL=https://dpllasnpfskyyyzebyal.supabase.co
PI_ACCESS_TOKEN=
PI_REFRESH_TOKEN=
SUPABASE_PUBLISHABLE_KEY=
OPENCLAW_BRIDGE_NODE_NAME=raspberry-pi5
OPENCLAW_ROOT=$ROOT
OPENCLAW_RUNTIME_DIR=$RUNTIME_DIR
SESSION_ENV_PATH=$ENV_FILE
CANONICAL_CONFIG_PATH=$RUNTIME_DIR/canonical-client.json
CANONICAL_CLIENT_ENV_PATH=$RUNTIME_DIR/supabase-client.env
EOF
  chmod 600 "$ENV_FILE"
  echo "RESULT=PI_SESSION_ENV_CREATED"
  echo "ENV_FILE=$ENV_FILE"
  echo "NEXT=insert a current short-lived PI_ACCESS_TOKEN and optional PI_REFRESH_TOKEN, then rerun"
  exit 22
fi
chmod 600 "$ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ "${SUPABASE_URL:-}" == https://* ]] || {
  echo "BLOCKED=HTTPS_SUPABASE_URL_REQUIRED" >&2
  exit 23
}
[[ ${#PI_ACCESS_TOKEN} -ge 20 ]] || {
  echo "BLOCKED=CURRENT_SHORT_LIVED_PI_JWT_REQUIRED" >&2
  exit 24
}

write_service() {
  local service_name="$1"
  local action="$2"
  cat > "$UNIT_DIR/$service_name.service" <<EOF
[Unit]
Description=OpenClaw Supabase bridge $action
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/env python3 $AGENT $action
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$RUNTIME_DIR $ENV_FILE
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6
SystemCallArchitectures=native
TimeoutStartSec=120
EOF
}

write_timer() {
  local timer_name="$1"
  local on_boot="$2"
  local interval="$3"
  local jitter="$4"
  cat > "$UNIT_DIR/$timer_name.timer" <<EOF
[Unit]
Description=Schedule $timer_name

[Timer]
OnBootSec=$on_boot
OnUnitActiveSec=$interval
RandomizedDelaySec=$jitter
Persistent=true
Unit=$timer_name.service

[Install]
WantedBy=timers.target
EOF
}

write_service openclaw-bridge-heartbeat heartbeat
write_timer openclaw-bridge-heartbeat 2min 5min 30

write_service openclaw-bridge-canonical-config config
write_timer openclaw-bridge-canonical-config 4min 6h 5min

write_service openclaw-bridge-credential-readiness credentials
write_timer openclaw-bridge-credential-readiness 10min 24h 10min

write_service openclaw-bridge-command-status command-status
write_timer openclaw-bridge-command-status 6min 30min 2min

systemctl --user daemon-reload

# Fail closed: do not enable timers until the full authenticated verification
# chain passes, including modern server-key runtime receipts.
"$AGENT" verify

systemctl --user enable --now \
  openclaw-bridge-heartbeat.timer \
  openclaw-bridge-canonical-config.timer \
  openclaw-bridge-credential-readiness.timer \
  openclaw-bridge-command-status.timer

systemctl --user start openclaw-bridge-heartbeat.service
systemctl --user start openclaw-bridge-canonical-config.service

printf '%s\n' \
  'RESULT=OPENCLAW_SUPABASE_BRIDGE_VERIFIED' \
  'SUPABASE_CLIENT_KEY=CANONICAL_MODERN_PUBLISHABLE' \
  'SUPABASE_SERVER_KEY=MODERN_SECRET_RUNTIME_RECEIPTS_VERIFIED' \
  'HEARTBEAT_TIMER=ENABLED_5_MINUTES' \
  'CANONICAL_CONFIG_TIMER=ENABLED_6_HOURS' \
  'CREDENTIAL_READINESS_TIMER=ENABLED_DAILY' \
  'COMMAND_STATUS_TIMER=ENABLED_30_MINUTES' \
  'PAID_API_FALLBACK=OFF' \
  'PUBLIC_SHELL=OFF' \
  'SECOND_TELEGRAM_POLLER=OFF' \
  "RECEIPT=$RUNTIME_DIR/bridge-verification-receipt.json" \
  "ROLLBACK=$SCRIPT_DIR/uninstall-openclaw-bridge-agent.sh"
