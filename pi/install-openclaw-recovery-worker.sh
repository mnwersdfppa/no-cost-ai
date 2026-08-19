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
WORKER_SOURCE="$SCRIPT_DIR/openclaw-recovery-worker.py"
FALLBACK_SOURCE="$SCRIPT_DIR/recover-openclaw-telegram-models.sh"
WORKER_TARGET="$BIN_DIR/openclaw-recovery-worker"
FALLBACK_TARGET="$BIN_DIR/openclaw-local-fallback-repair"
SERVICE_FILE="$USER_SYSTEMD_DIR/openclaw-pi-recovery-worker.service"
TIMER_FILE="$USER_SYSTEMD_DIR/openclaw-pi-recovery-worker.timer"
RECEIPT="$RUNTIME_DIR/openclaw-recovery-worker-install-receipt.json"

fail() {
  printf 'BLOCKED=%s\n' "$1" >&2
  exit 40
}

command -v python3 >/dev/null 2>&1 || fail "python3_missing"
command -v systemctl >/dev/null 2>&1 || fail "systemctl_missing"
[[ -f "$WORKER_SOURCE" ]] || fail "worker_source_missing"
[[ -f "$FALLBACK_SOURCE" ]] || fail "fallback_source_missing"

mkdir -p "$BIN_DIR" "$SECRETS_DIR" "$RUNTIME_DIR" "$USER_SYSTEMD_DIR"
chmod 700 "$BIN_DIR" "$SECRETS_DIR" "$RUNTIME_DIR"

install -m 0700 "$WORKER_SOURCE" "$WORKER_TARGET"
install -m 0700 "$FALLBACK_SOURCE" "$FALLBACK_TARGET"
python3 -m py_compile "$WORKER_TARGET"
"$WORKER_TARGET" --self-test >/dev/null
bash -n "$FALLBACK_TARGET"

cat >"$SERVICE_FILE" <<'UNIT'
[Unit]
Description=OpenClaw bounded Supabase recovery queue worker
After=network-online.target
Wants=network-online.target
ConditionPathExists=%h/.openclaw/secrets/pi-work-queue.env

[Service]
Type=oneshot
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=%h/.openclaw/secrets/pi-work-queue.env
ExecStart=%h/.openclaw/bin/openclaw-recovery-worker
TimeoutStartSec=1200
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
Description=Run OpenClaw bounded recovery worker every two minutes

[Timer]
OnBootSec=90s
OnUnitActiveSec=2min
RandomizedDelaySec=30s
Persistent=true
Unit=openclaw-pi-recovery-worker.service

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
ENV
  chmod 600 "$SESSION_ENV"
  python3 - "$RECEIPT" <<'PY'
import json, pathlib, sys
path=pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
  "result":"installed_blocked_session_missing",
  "timer_enabled":False,
  "allowed_task_types":[
    "pi_supabase_auth_model_recovery",
    "worker_liveness_guardian",
    "telegram_model_failover_repair"
  ],
  "arbitrary_payload_execution":False,
  "second_telegram_poller_created":False,
  "secret_values_included":False
},indent=2,sort_keys=True)+"\n",encoding="utf-8")
path.chmod(0o600)
PY
  fail "pi_session_env_created_but_token_missing"
fi

chmod 600 "$SESSION_ENV"
# shellcheck disable=SC1090
source "$SESSION_ENV"
if [[ ${#PI_ACCESS_TOKEN:-0} -lt 20 && ${#PI_REFRESH_TOKEN:-0} -lt 20 ]]; then
  fail "pi_access_or_refresh_token_required"
fi
if [[ "${SUPABASE_URL:-}" != "https://dpllasnpfskyyyzebyal.supabase.co" ]]; then
  fail "unexpected_supabase_project"
fi

systemctl --user enable --now openclaw-pi-recovery-worker.timer
systemctl --user start openclaw-pi-recovery-worker.service || true

TIMER_ACTIVE=false
if systemctl --user is-active --quiet openclaw-pi-recovery-worker.timer; then
  TIMER_ACTIVE=true
fi

python3 - "$RECEIPT" "$TIMER_ACTIVE" <<'PY'
import json, pathlib, sys
path=pathlib.Path(sys.argv[1])
active=sys.argv[2].lower()=="true"
path.write_text(json.dumps({
  "result":"installed",
  "timer_enabled":active,
  "interval":"2min+jitter",
  "allowed_task_types":[
    "pi_supabase_auth_model_recovery",
    "worker_liveness_guardian",
    "telegram_model_failover_repair"
  ],
  "arbitrary_payload_execution":False,
  "unknown_process_kill":False,
  "second_telegram_poller_created":False,
  "secret_values_included":False
},indent=2,sort_keys=True)+"\n",encoding="utf-8")
path.chmod(0o600)
PY

printf 'RESULT=installed timer_active=%s receipt=%s\n' "$TIMER_ACTIVE" "$RECEIPT"
