#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
BIN_DIR="$ROOT/bin"
RUNTIME_DIR="$ROOT/runtime"
SECRETS_DIR="$ROOT/secrets"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
WORKER="$BIN_DIR/openclaw-external-scheduler-actuator-v3.py"
DISABLE="$BIN_DIR/openclaw-disable-project-schedulers-v3"
ROLLBACK="$BIN_DIR/openclaw-rollback-project-schedulers-v3"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$SECRETS_DIR/pi-work-queue.env}"
RECEIPT="$RUNTIME_DIR/external-scheduler-actuator-v3-install-receipt.json"
SERVICE="openclaw-external-scheduler-actuator.service"
TIMER="openclaw-external-scheduler-actuator.timer"

BASE_URL="https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/ff3f0fad54c33498edb92dec985a8f1e043ef7f0"
WORKER_URL="$BASE_URL/pi/external-scheduler-actuator-v3.py"
DISABLE_URL="$BASE_URL/scripts/disable-project-schedulers-v3.sh"
ROLLBACK_URL="$BASE_URL/scripts/rollback-project-schedulers-v3.sh"
WORKER_SHA256="3e18afdaac6fa376367dbd8e8840ea1039b38edca09c47530e8c38dcc6595606"
DISABLE_SHA256="9151a4dbf25cc88237864a60a2940e09c600ff747efe30f4e354d5a584b66cd7"
ROLLBACK_SHA256="98eba0554f23d57d63798b9db5fab1468cc4558ed4335befb080fab3c719c99f"

fail() {
  printf 'ACTUATOR_V3_INSTALL_BLOCKED reason=%s\n' "$1" >&2
  exit "${2:-40}"
}

for command in bash curl python3 sha256sum systemctl install mktemp grep; do
  command -v "$command" >/dev/null 2>&1 || fail "missing_$command"
done

mkdir -p "$BIN_DIR" "$RUNTIME_DIR" "$SECRETS_DIR" "$UNIT_DIR"
chmod 700 "$BIN_DIR" "$RUNTIME_DIR" "$SECRETS_DIR" "$UNIT_DIR"

TMP_DIR="$(mktemp -d "$RUNTIME_DIR/.external-actuator-v3-install.XXXXXX")"
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
grep -Fq 'OPENCLAW_NATIVE_CRON_KILL_SWITCH_UNCONFIRMED' "$TMP_DIR/worker.py"
grep -Fq 'Environment=OPENCLAW_SKIP_CRON=1' "$TMP_DIR/disable.sh"
grep -Fq '90-external-macro-owner.conf' "$TMP_DIR/disable.sh"
grep -Fq 'openclaw-native-cron-kill-switch' "$TMP_DIR/disable.sh" || \
  grep -Fq 'openclaw_native_cron_kill_switch' "$TMP_DIR/disable.sh"
grep -Fq 'unset-environment OPENCLAW_SKIP_CRON' "$TMP_DIR/rollback.sh"

if grep -Eq 'curl[[:space:]]*\|[[:space:]]*(sh|bash)|shell[[:space:]]*=[[:space:]]*True|getUpdates|rm[[:space:]]+-rf[[:space:]]+/' \
  "$TMP_DIR/worker.py" "$TMP_DIR/disable.sh" "$TMP_DIR/rollback.sh"; then
  fail "artifact_contract_rejected"
fi

install -m 0700 "$TMP_DIR/worker.py" "$WORKER"
install -m 0700 "$TMP_DIR/disable.sh" "$DISABLE"
install -m 0700 "$TMP_DIR/rollback.sh" "$ROLLBACK"

cat > "$UNIT_DIR/$SERVICE" <<EOF_SERVICE
[Unit]
Description=OpenClaw fixed external scheduler handoff actuator v3
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
ReadWritePaths=$ROOT $UNIT_DIR
ProtectHome=read-only
EOF_SERVICE

cat > "$UNIT_DIR/$TIMER" <<EOF_TIMER
[Unit]
Description=Schedule OpenClaw external scheduler handoff actuator v3

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
RandomizedDelaySec=20s
AccuracySec=15s
Persistent=true
Unit=$SERVICE

[Install]
WantedBy=timers.target
EOF_TIMER

chmod 600 "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
systemctl --user daemon-reload
systemctl --user enable --now "$TIMER"

# Trigger one immediate bounded attempt. Authentication or network failure is
# left to the timer's retry cycle and does not invalidate installation.
immediate_attempted=true
immediate_succeeded=false
if systemctl --user start "$SERVICE"; then
  immediate_succeeded=true
fi

timer_active=false
if systemctl --user is-active --quiet "$TIMER"; then
  timer_active=true
fi

python3 - "$RECEIPT" "$WORKER_SHA256" "$DISABLE_SHA256" "$ROLLBACK_SHA256" \
  "$timer_active" "$immediate_attempted" "$immediate_succeeded" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = {
    "result": "installed",
    "contract_version": 3,
    "worker": "openclaw-external-scheduler-actuator-v3.py",
    "worker_sha256": sys.argv[2],
    "disable_script_sha256": sys.argv[3],
    "rollback_script_sha256": sys.argv[4],
    "timer": "openclaw-external-scheduler-actuator.timer",
    "timer_active": sys.argv[5].lower() == "true",
    "immediate_attempted": sys.argv[6].lower() == "true",
    "immediate_succeeded": sys.argv[7].lower() == "true",
    "interval": "5min+jitter",
    "task_key": "external-local-scheduler-disable-v1",
    "task_type": "external_scheduler_reconcile",
    "fixed_endpoint": "pi-external-scheduler-handoff-20260822",
    "openclaw_native_cron_kill_switch": "OPENCLAW_SKIP_CRON=1",
    "rollback_command": str(
        pathlib.Path.home()
        / ".openclaw/bin/openclaw-rollback-project-schedulers-v3"
    ),
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

printf 'EXTERNAL_SCHEDULER_ACTUATOR_V3_INSTALLED timer=%s immediate=%s receipt=%s\n' \
  "$TIMER" "$immediate_succeeded" "$RECEIPT"
