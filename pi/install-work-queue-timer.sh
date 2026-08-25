#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="$ROOT_DIR/pi-work-queue-worker.py"
ENV_DIR="$HOME/.openclaw/secrets"
ENV_FILE="$ENV_DIR/pi-work-queue.env"
UNIT_DIR="$HOME/.config/systemd/user"

command -v python3 >/dev/null 2>&1 || { echo 'ERROR: python3 is required' >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo 'ERROR: systemd user services are required' >&2; exit 1; }
[[ -f "$WORKER" ]] || { echo "ERROR: worker not found: $WORKER" >&2; exit 1; }

mkdir -p "$ENV_DIR" "$UNIT_DIR"
chmod 700 "$HOME/.openclaw" "$ENV_DIR"
chmod 700 "$WORKER"

if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<'EOF'
SUPABASE_URL=https://dpllasnpfskyyyzebyal.supabase.co
PI_ACCESS_TOKEN=
EOF
  chmod 600 "$ENV_FILE"
  echo "CREATED_ENV_FILE=$ENV_FILE"
  echo 'Fill PI_ACCESS_TOKEN with a current short-lived Pi user JWT, then rerun this installer.'
  exit 20
fi

chmod 600 "$ENV_FILE"
if ! grep -Eq '^PI_ACCESS_TOKEN=.{20,}$' "$ENV_FILE"; then
  echo "ERROR: PI_ACCESS_TOKEN is missing in $ENV_FILE" >&2
  exit 20
fi

cat > "$UNIT_DIR/openclaw-work-queue.service" <<EOF
[Unit]
Description=OpenClaw bounded work queue worker
After=network-online.target openclaw-gateway.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/env python3 $WORKER
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$HOME/.openclaw $ROOT_DIR
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
TimeoutStartSec=120
EOF

cat > "$UNIT_DIR/openclaw-work-queue.timer" <<'EOF'
[Unit]
Description=Run OpenClaw bounded queue every 15 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=15min
RandomizedDelaySec=60
Persistent=true
Unit=openclaw-work-queue.service

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now openclaw-work-queue.timer
systemctl --user start openclaw-work-queue.service || true
systemctl --user status openclaw-work-queue.timer --no-pager || true

echo 'WORK_QUEUE_TIMER=ENABLED'
