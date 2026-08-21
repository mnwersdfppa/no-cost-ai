#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
BIN_DIR="$ROOT/bin"
RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-$ROOT/runtime}"
SECRETS_DIR="$ROOT/secrets"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
WORKER="$BIN_DIR/openclaw-recovery-worker-current.py"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$SECRETS_DIR/pi-work-queue.env}"
RECEIPT="$RUNTIME_DIR/openclaw-recovery-worker-current-install-receipt.json"
SOURCE_URL="https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/c90ad40bd2ef8a8430cdf78bd5f1a394d2812eab/pi/openclaw-recovery-worker-current.py"
SOURCE_SHA256="bef134f66bb3da5187c3842db3e765471e02c0a058c70c7b79c57cf989112589"
SERVICE="openclaw-pi-recovery-worker-current.service"
TIMER="openclaw-pi-recovery-worker-current.timer"

fail() {
  printf 'BLOCKED=%s\n' "$1" >&2
  exit "${2:-40}"
}

for command in bash curl python3 sha256sum systemctl; do
  command -v "$command" >/dev/null 2>&1 || fail "missing_$command"
done

mkdir -p "$BIN_DIR" "$RUNTIME_DIR" "$SECRETS_DIR" "$UNIT_DIR"
chmod 700 "$BIN_DIR" "$RUNTIME_DIR" "$SECRETS_DIR" "$UNIT_DIR"

tmp="$(mktemp "$RUNTIME_DIR/.openclaw-recovery-worker-current.XXXXXX.py")"
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT

curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
  -o "$tmp" "$SOURCE_URL"
printf '%s  %s\n' "$SOURCE_SHA256" "$tmp" | sha256sum -c -
python3 -m py_compile "$tmp"
python3 "$tmp" --self-test
grep -Fq 'MIN_REFRESH_TOKEN_CHARS = 8' "$tmp"
grep -Fq 'pi-recovery-installer-current-format-verified' "$tmp"
telegram_marker="TELEGRAM_"'BOT_TOKEN'
if grep -Fq "$telegram_marker" "$tmp"; then
  fail "worker_contract_rejected"
fi
if grep -Eq 'shell[[:space:]]*=[[:space:]]*True|curl[[:space:]]*\|[[:space:]]*(sh|bash)' "$tmp"; then
  fail "worker_contract_rejected"
fi
install -m 0700 "$tmp" "$WORKER"

cat > "$UNIT_DIR/$SERVICE" <<EOF
[Unit]
Description=OpenClaw deterministic recovery queue worker
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=OPENCLAW_ROOT=$ROOT
Environment=OPENCLAW_RUNTIME_DIR=$RUNTIME_DIR
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
Description=Schedule OpenClaw deterministic recovery worker

[Timer]
OnBootSec=90s
OnUnitActiveSec=2min
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

python3 - "$RECEIPT" "$SOURCE_SHA256" "$timer_active" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    json.dumps(
        {
            "result": "installed",
            "worker": "openclaw-recovery-worker-current.py",
            "worker_sha256": sys.argv[2],
            "refresh_token_minimum_chars": 8,
            "recovery_installer": "pi-recovery-installer-current-format-verified",
            "queue_contract_version": 2,
            "allowed_task_types": [
                "pi_supabase_auth_model_recovery",
                "worker_liveness_guardian",
                "telegram_model_failover_repair",
            ],
            "timer_active": sys.argv[3].lower() == "true",
            "interval": "2min+jitter",
            "arbitrary_payload_execution": False,
            "provider_secret_exported": False,
            "second_telegram_poller_created": False,
            "paid_api_fallback": False,
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

printf 'RESULT=installed worker=%s timer=%s receipt=%s\n' "$WORKER" "$TIMER" "$RECEIPT"
