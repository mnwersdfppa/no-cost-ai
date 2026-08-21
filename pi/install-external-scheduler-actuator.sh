#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
BIN_DIR="$ROOT/bin"
RUNTIME_DIR="$ROOT/runtime"
SECRETS_DIR="$ROOT/secrets"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
WORKER="$BIN_DIR/openclaw-external-scheduler-actuator.py"
DISABLE="$BIN_DIR/openclaw-disable-project-schedulers"
ROLLBACK="$BIN_DIR/openclaw-rollback-project-schedulers"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$SECRETS_DIR/pi-work-queue.env}"
RECEIPT="$RUNTIME_DIR/external-scheduler-actuator-install-receipt.json"
SERVICE="openclaw-external-scheduler-actuator.service"
TIMER="openclaw-external-scheduler-actuator.timer"

BASE_URL="https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/c0cd1b34be4e32a83e1ac058664f3f5fe596a932"
WORKER_URL="$BASE_URL/pi/external-scheduler-actuator.py"
DISABLE_URL="$BASE_URL/scripts/disable-project-schedulers-v2.sh"
ROLLBACK_URL="$BASE_URL/scripts/rollback-project-schedulers-v2.sh"
WORKER_SHA256="0d68123302e0d74efe9ee86dc8ebc02b3e35861d7dbe77b193181669b8e08859"
DISABLE_SHA256="d45c42e950c4b8f18be146bd5aeae185b72b43f84f114bf84d7cce26fc7a45b5"
ROLLBACK_SHA256="413afa709b0b78e928b62ba218ba82edbe8fb8f848b8ea0175af53648840ec58"

fail() {
  printf 'ACTUATOR_INSTALL_BLOCKED reason=%s\n' "$1" >&2
  exit "${2:-40}"
}

for command in bash curl python3 sha256sum systemctl install mktemp; do
  command -v "$command" >/dev/null 2>&1 || fail "missing_$command"
done

mkdir -p "$BIN_DIR" "$RUNTIME_DIR" "$SECRETS_DIR" "$UNIT_DIR"
chmod 700 "$BIN_DIR" "$RUNTIME_DIR" "$SECRETS_DIR" "$UNIT_DIR"

TMP_DIR="$(mktemp -d "$RUNTIME_DIR/.external-actuator-install.XXXXXX")"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
  -o "$TMP_DIR/worker.py" "$WORKER_URL"
curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
  -o "$TMP_DIR/disable.sh" "$DISABLE_URL"
curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
  -o "$TMP_DIR/rollback.sh" "$ROLLBACK_URL"

printf '%s  %s\n' "$WORKER_SHA256" "$TMP_DIR/worker.py" | sha256sum -c -
printf '%s  %s\n' "$DISABLE_SHA256" "$TMP_DIR/disable.sh" | sha256sum -c -
printf '%s  %s\n' "$ROLLBACK_SHA256" "$TMP_DIR/rollback.sh" | sha256sum -c -

python3 -m py_compile "$TMP_DIR/worker.py"
python3 "$TMP_DIR/worker.py" --self-test
bash -n "$TMP_DIR/disable.sh"
bash -n "$TMP_DIR/rollback.sh"

grep -Fq 'external-local-scheduler-disable-v1' "$TMP_DIR/worker.py"
grep -Fq 'pi-external-scheduler-handoff-20260822' "$TMP_DIR/worker.py"
grep -Fq 'openclaw-external-scheduler-actuator.timer' "$TMP_DIR/disable.sh"
grep -Fq 'openclaw-pi-recovery-worker-current.timer' "$TMP_DIR/disable.sh"
grep -Fq 'openclaw-pi-session-refresh.timer' "$TMP_DIR/disable.sh"
grep -Fq 'openclaw-telegram-delivery-worker.timer' "$TMP_DIR/disable.sh"

if grep -Eq 'curl[[:space:]]*\|[[:space:]]*(sh|bash)|shell[[:space:]]*=[[:space:]]*True|getUpdates' \
  "$TMP_DIR/worker.py" "$TMP_DIR/disable.sh" "$TMP_DIR/rollback.sh"; then
  fail "artifact_contract_rejected"
fi

install -m 0700 "$TMP_DIR/worker.py" "$WORKER"
install -m 0700 "$TMP_DIR/disable.sh" "$DISABLE"
install -m 0700 "$TMP_DIR/rollback.sh" "$ROLLBACK"

cat > "$UNIT_DIR/$SERVICE" <<EOF
[Unit]
Description=OpenClaw fixed external scheduler handoff actuator
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=OPENCLAW_STATE_DIR=$ROOT
Environment=PI_WORK_QUEUE_ENV=$ENV_FILE
EnvironmentFile=-$ENV_FILE
ExecStart=/usr/bin/python3 $WORKER
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$ROOT
ProtectHome=read-only
EOF

cat > "$UNIT_DIR/$TIMER" <<EOF
[Unit]
Description=Schedule OpenClaw external scheduler handoff actuator

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
AccuracySec=15s
Persistent=true
Unit=$SERVICE

[Install]
WantedBy=timers.target
EOF

chmod 600 "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
systemctl --user daemon-reload
systemctl --user enable --now "$TIMER"

timer_active=false
if systemctl --user is-active --quiet "$TIMER"; then
  timer_active=true
fi

python3 - "$RECEIPT" "$WORKER_SHA256" "$DISABLE_SHA256" "$ROLLBACK_SHA256" "$timer_active" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = {
    "result": "installed",
    "worker": "openclaw-external-scheduler-actuator.py",
    "worker_sha256": sys.argv[2],
    "disable_script_sha256": sys.argv[3],
    "rollback_script_sha256": sys.argv[4],
    "timer": "openclaw-external-scheduler-actuator.timer",
    "timer_active": sys.argv[5].lower() == "true",
    "interval": "5min+jitter",
    "task_key": "external-local-scheduler-disable-v1",
    "task_type": "external_scheduler_reconcile",
    "fixed_endpoint": "pi-external-scheduler-handoff-20260822",
    "preserved_control_timers": [
        "openclaw-pi-recovery-worker-current.timer",
        "openclaw-pi-session-refresh.timer",
        "openclaw-telegram-delivery-worker.timer",
        "openclaw-external-scheduler-actuator.timer",
    ],
    "arbitrary_command_execution": False,
    "automatic_reboot": False,
    "unknown_process_kill": False,
    "second_telegram_poller_created": False,
    "paid_api_fallback": False,
    "secret_values_included": False,
}
path.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
path.chmod(0o600)
PY

printf 'EXTERNAL_SCHEDULER_ACTUATOR_INSTALLED timer=%s receipt=%s\n' \
  "$TIMER" "$RECEIPT"
