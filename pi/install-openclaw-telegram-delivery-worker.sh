#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
BIN_DIR="$ROOT/bin"
SECRETS_DIR="$ROOT/secrets"
RUNTIME_DIR="$ROOT/runtime"
USER_SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SESSION_ENV="${PI_WORK_QUEUE_ENV:-$SECRETS_DIR/pi-work-queue.env}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/openclaw-telegram-delivery-worker.py"
TARGET="$BIN_DIR/openclaw-telegram-delivery-worker"
SERVICE_FILE="$USER_SYSTEMD_DIR/openclaw-telegram-delivery-worker.service"
TIMER_FILE="$USER_SYSTEMD_DIR/openclaw-telegram-delivery-worker.timer"
RECEIPT="$RUNTIME_DIR/openclaw-telegram-delivery-worker-install-receipt.json"

fail() {
  printf 'BLOCKED=%s\n' "$1" >&2
  exit 40
}

for command in python3 systemctl openclaw; do
  command -v "$command" >/dev/null 2>&1 || fail "${command}_missing"
done
[[ -f "$SOURCE" ]] || fail "delivery_worker_source_missing"

mkdir -p "$BIN_DIR" "$SECRETS_DIR" "$RUNTIME_DIR" "$USER_SYSTEMD_DIR"
chmod 700 "$BIN_DIR" "$SECRETS_DIR" "$RUNTIME_DIR"

install -m 0700 "$SOURCE" "$TARGET"
python3 -m py_compile "$TARGET"
"$TARGET" --self-test >/dev/null

cat >"$SERVICE_FILE" <<'UNIT'
[Unit]
Description=OpenClaw outbound-only Telegram result delivery worker
After=network-online.target
Wants=network-online.target
ConditionPathExists=%h/.openclaw/secrets/pi-work-queue.env

[Service]
Type=oneshot
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=%h/.openclaw/secrets/pi-work-queue.env
ExecStart=%h/.openclaw/bin/openclaw-telegram-delivery-worker
TimeoutStartSec=180
Nice=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.openclaw
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true
RestrictRealtime=true
UMask=0077
UNIT

cat >"$TIMER_FILE" <<'UNIT'
[Unit]
Description=Deliver queued OpenClaw Telegram results every two minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
RandomizedDelaySec=20s
Persistent=true
Unit=openclaw-telegram-delivery-worker.service

[Install]
WantedBy=timers.target
UNIT

chmod 600 "$SERVICE_FILE" "$TIMER_FILE"
systemctl --user daemon-reload

if [[ ! -f "$SESSION_ENV" ]]; then
  cat >"$SESSION_ENV" <<'ENV'
SUPABASE_URL=https://dpllasnpfskyyyzebyal.supabase.co
PI_ACCESS_TOKEN=
PI_REFRESH_TOKEN=
OPENCLAW_TELEGRAM_TARGET=
ENV
  chmod 600 "$SESSION_ENV"
  fail "pi_session_env_created_but_token_missing"
fi

chmod 600 "$SESSION_ENV"
# shellcheck disable=SC1090
source "$SESSION_ENV"
if [[ "${SUPABASE_URL:-}" != "https://dpllasnpfskyyyzebyal.supabase.co" ]]; then
  fail "unexpected_supabase_project"
fi
if [[ ${#PI_ACCESS_TOKEN:-0} -lt 20 && ${#PI_REFRESH_TOKEN:-0} -lt 20 ]]; then
  fail "pi_access_or_refresh_token_required"
fi

systemctl --user enable --now openclaw-telegram-delivery-worker.timer
systemctl --user start openclaw-telegram-delivery-worker.service || true

TIMER_ACTIVE=false
if systemctl --user is-active --quiet openclaw-telegram-delivery-worker.timer; then
  TIMER_ACTIVE=true
fi

python3 - "$RECEIPT" "$TIMER_ACTIVE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
active = sys.argv[2].lower() == "true"
path.write_text(
    json.dumps(
        {
            "result": "installed",
            "worker": "openclaw-telegram-delivery-worker",
            "timer_enabled": active,
            "interval": "2min+jitter",
            "queue_endpoint": "pi-result-delivery-queue",
            "task_type": "telegram_result_delivery",
            "delivery_command": "openclaw message send",
            "target_resolution": [
                "queue_payload",
                "OPENCLAW_TELEGRAM_TARGET",
                "openclaw_config_single_allowFrom",
            ],
            "outbound_only": True,
            "second_telegram_poller_created": False,
            "provider_secret_exported": False,
            "secret_values_included": False,
        },
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
path.chmod(0o600)
PY

printf 'RESULT=installed worker=openclaw-telegram-delivery-worker timer_active=%s receipt=%s\n' \
  "$TIMER_ACTIVE" "$RECEIPT"
