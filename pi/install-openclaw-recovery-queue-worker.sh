#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/openclaw-recovery-queue-worker.py"
ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
BIN_DIR="$ROOT/bin"
RUNTIME_DIR="$ROOT/runtime"
SECRETS_DIR="$ROOT/secrets"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$SECRETS_DIR/pi-work-queue.env}"
UNIT_DIR="$HOME/.config/systemd/user"
WORKER="$BIN_DIR/openclaw-recovery-queue-worker"
SERVICE="openclaw-recovery-queue.service"
TIMER="openclaw-recovery-queue.timer"

fail() {
  printf 'RESULT=BLOCKED\nBLOCKER=%s\n' "$1" >&2
  exit "${2:-1}"
}

for command in python3 systemctl install; do
  command -v "$command" >/dev/null 2>&1 || fail "MISSING_COMMAND:$command" 20
done
[[ -r "$SOURCE" ]] || fail "WORKER_SOURCE_MISSING:$SOURCE" 21
[[ -r "$ENV_FILE" ]] || fail "PI_SESSION_ENV_MISSING:$ENV_FILE" 22

mkdir -p "$BIN_DIR" "$RUNTIME_DIR" "$SECRETS_DIR" "$UNIT_DIR"
chmod 700 "$ROOT" "$BIN_DIR" "$RUNTIME_DIR" "$SECRETS_DIR"
chmod 600 "$ENV_FILE"
python3 -m py_compile "$SOURCE"
install -m 700 "$SOURCE" "$WORKER"

cat > "$UNIT_DIR/$SERVICE" <<EOF
[Unit]
Description=OpenClaw deterministic Supabase recovery queue worker
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
Environment=OPENCLAW_ROOT=$ROOT
Environment=OPENCLAW_RUNTIME_DIR=$RUNTIME_DIR
Environment=PI_WORK_QUEUE_ENV=$ENV_FILE
ExecStart=/usr/bin/env python3 $WORKER
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$ROOT $UNIT_DIR
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native
TimeoutStartSec=1900
EOF

cat > "$UNIT_DIR/$TIMER" <<EOF
[Unit]
Description=Schedule OpenClaw deterministic recovery queue worker

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
RandomizedDelaySec=30s
Persistent=true
Unit=$SERVICE

[Install]
WantedBy=timers.target
EOF

chmod 600 "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
systemctl --user daemon-reload
systemctl --user enable --now "$TIMER"
systemctl --user start "$SERVICE"
systemctl --user is-enabled "$TIMER" >/dev/null

printf '%s\n' \
  'RESULT=OPENCLAW_RECOVERY_QUEUE_WORKER_INSTALLED' \
  'CLAIM_SCOPE=DETERMINISTIC_RECOVERY_ALLOWLIST' \
  'ALLOWED_TASK_TYPES=pi_supabase_auth_model_recovery,telegram_model_failover_repair,worker_liveness_guardian' \
  'ARBITRARY_QUEUE_COMMAND_EXECUTION=OFF' \
  'SECOND_TELEGRAM_POLLER=OFF' \
  "WORKER=$WORKER" \
  "TIMER=$TIMER" \
  "RECEIPT=$RUNTIME_DIR/openclaw-recovery-queue-receipt.json"
