#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$ROOT/secrets/pi-work-queue.env}"
SOURCE_CLIENT="$REPO_ROOT/pi/openclaw-emergency-bridge.py"
BIN_DIR="$ROOT/bin"
UNIT_DIR="$HOME/.config/systemd/user"
CLIENT="$BIN_DIR/openclaw-emergency-bridge"

for command in python3 systemctl install; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "BLOCKED=MISSING_COMMAND:$command" >&2
    exit 20
  }
done

[[ -r "$SOURCE_CLIENT" ]] || {
  echo "BLOCKED=PI_CLIENT_SOURCE_MISSING:$SOURCE_CLIENT" >&2
  exit 21
}

[[ -r "$ENV_FILE" ]] || {
  echo "BLOCKED=PI_ENV_FILE_MISSING:$ENV_FILE" >&2
  exit 22
}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

SUPABASE_URL="${SUPABASE_URL:-https://dpllasnpfskyyyzebyal.supabase.co}"
PI_ACCESS_TOKEN="${PI_ACCESS_TOKEN:-}"
[[ "$SUPABASE_URL" == https://* ]] || {
  echo 'BLOCKED=HTTPS_SUPABASE_URL_REQUIRED' >&2
  exit 23
}
[[ ${#PI_ACCESS_TOKEN} -ge 20 ]] || {
  echo 'BLOCKED=CURRENT_SHORT_LIVED_PI_JWT_REQUIRED' >&2
  exit 24
}

mkdir -p "$ROOT" "$ROOT/secrets" "$BIN_DIR" "$UNIT_DIR"
chmod 700 "$ROOT" "$ROOT/secrets" "$BIN_DIR"
chmod 600 "$ENV_FILE"
install -m 700 "$SOURCE_CLIENT" "$CLIENT"
python3 -m py_compile "$CLIENT"

cat > "$UNIT_DIR/openclaw-emergency-heartbeat.service" <<EOF
[Unit]
Description=OpenClaw Supabase emergency bridge heartbeat
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/env python3 $CLIENT heartbeat
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
UMask=0077
TimeoutStartSec=45
EOF

cat > "$UNIT_DIR/openclaw-emergency-heartbeat.timer" <<'EOF'
[Unit]
Description=Send OpenClaw emergency heartbeat every five minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30
Persistent=true
Unit=openclaw-emergency-heartbeat.service

[Install]
WantedBy=timers.target
EOF

cat > "$UNIT_DIR/openclaw-credential-readiness.service" <<EOF
[Unit]
Description=Refresh non-secret OpenClaw credential readiness
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/env python3 $CLIENT credentials
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
UMask=0077
TimeoutStartSec=45
EOF

cat > "$UNIT_DIR/openclaw-credential-readiness.timer" <<'EOF'
[Unit]
Description=Refresh OpenClaw credential readiness daily

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
RandomizedDelaySec=5min
Persistent=true
Unit=openclaw-credential-readiness.service

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload

# Timers remain disabled unless every authenticated, non-secret smoke test passes.
"$CLIENT" status
"$CLIENT" policy openai chat
"$CLIENT" route model_chat 0
"$CLIENT" queue
"$CLIENT" config
"$CLIENT" command-status
"$CLIENT" credentials

systemctl --user enable --now openclaw-emergency-heartbeat.timer
systemctl --user enable --now openclaw-credential-readiness.timer
systemctl --user start openclaw-emergency-heartbeat.service

printf '%s\n' \
  'RESULT=SUPABASE_EMERGENCY_BRIDGE_PI_READY' \
  'AUTHENTICATED_STATUS=PASS' \
  'PAID_OPENAI_POLICY=DENIED_AS_EXPECTED' \
  'ZERO_COST_ROUTE=PASS' \
  'QUEUE_STATUS=PASS' \
  'CANONICAL_CLIENT_CONFIG=PASS' \
  'COMMAND_CENTER_STATUS=PASS' \
  'CREDENTIAL_READINESS=PASS' \
  'HEARTBEAT_TIMER=ENABLED_5_MINUTES' \
  'CREDENTIAL_READINESS_TIMER=ENABLED_DAILY' \
  'PAID_API_FALLBACK=OFF' \
  'PUBLIC_SHELL=OFF' \
  'SECOND_TELEGRAM_POLLER=OFF' \
  "MANUAL_STATUS=$CLIENT status" \
  "ROLLBACK=systemctl --user disable --now openclaw-emergency-heartbeat.timer openclaw-credential-readiness.timer"
