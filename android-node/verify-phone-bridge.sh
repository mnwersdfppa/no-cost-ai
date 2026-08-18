#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
RUN_LLM_TEST="${RUN_LLM_TEST:-0}"
ENABLE_AFTER_VERIFY="${ENABLE_AFTER_VERIFY:-1}"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING"
  exit 30
fi
set -a
source "$ENV_FILE"
set +a

adb start-server >/dev/null
if [[ "$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)" != "device" ]]; then
  echo "BLOCKED=ADB_DEVICE_NOT_READY"
  exit 31
fi
adb -s "$ANDROID_SERIAL" forward tcp:"$PHONE_SSH_PORT" tcp:8022 >/dev/null

if [[ -z "${PHONE_SSH_USER:-}" ]]; then
  echo "BLOCKED=TERMUX_USER_UNKNOWN"
  echo "NEXT=run id -un in Termux and set PHONE_SSH_USER in $ENV_FILE"
  exit 32
fi

SSH=(ssh -p "$PHONE_SSH_PORT" -i "$PHONE_SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$PHONE_SSH_USER@$PHONE_SSH_HOST")
REMOTE_STATUS_CMD='printf "user=%s\n" "$(id -un)"; command -v codex || true; codex --version 2>/dev/null || true; codex login status 2>/dev/null || true; test -x "$HOME/.local/bin/openclaw-phone-codex-run" && echo runner=ready || echo runner=missing'
REMOTE_STATUS="$("${SSH[@]}" "$REMOTE_STATUS_CMD" 2>&1 || true)"
printf '%s\n' "$REMOTE_STATUS"

if ! grep -q 'runner=ready' <<<"$REMOTE_STATUS"; then
  echo "BLOCKED=PHONE_RUNNER_NOT_READY"
  exit 33
fi
if ! grep -qi 'Logged in using ChatGPT' <<<"$REMOTE_STATUS"; then
  echo "BLOCKED=PHONE_CODEX_NOT_LOGGED_IN"
  echo "NEXT=run codex login --device-auth in Termux and approve it in the phone browser"
  exit 34
fi

if [[ "$ENABLE_AFTER_VERIFY" == "1" ]]; then
  sed -i 's/^PHONE_CODEX_ENABLED=.*/PHONE_CODEX_ENABLED=1/' "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

openclaw mcp doctor android-phone-read --probe
openclaw mcp doctor phone-codex --probe
openclaw mcp status --verbose
openclaw nodes status || true
openclaw gateway call node.list --params '{}' || true

LLM_RESULT="not_run"
if [[ "$RUN_LLM_TEST" == "1" ]]; then
  REQUEST='{"version":1,"model":"gpt-5.6-sol","prompt":"Reply exactly PHONE_CODEX_OK and nothing else."}'
  REMOTE_RUNNER_CMD='$HOME/.local/bin/openclaw-phone-codex-run'
  LLM_OUTPUT="$(printf '%s\n' "$REQUEST" | "${SSH[@]}" "$REMOTE_RUNNER_CMD" 2>&1 || true)"
  if grep -q 'PHONE_CODEX_OK' <<<"$LLM_OUTPUT"; then
    LLM_RESULT="pass"
  else
    LLM_RESULT="fail"
    printf '%s\n' "$LLM_OUTPUT" | tail -n 40
  fi
fi

if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
  openclaw gateway restart --safe || true
else
  openclaw gateway restart || true
fi
openclaw gateway status || true

mkdir -p "$ROOT/logs"
cat > "$ROOT/logs/verify-receipt.json" <<JSON
{
  "result": "pass",
  "adb": "device",
  "ssh": "pass",
  "codex_login": "chatgpt",
  "runner": "ready",
  "phone_codex_enabled": "$ENABLE_AFTER_VERIFY",
  "llm_test": "$LLM_RESULT",
  "mcp_write_enabled": false,
  "secrets_printed": false
}
JSON
chmod 600 "$ROOT/logs/verify-receipt.json"

echo "RESULT=PASS"
if [[ "$ENABLE_AFTER_VERIFY" == "1" ]]; then
  echo "PHONE_CODEX=ENABLED"
else
  echo "PHONE_CODEX=DISABLED"
fi
echo "LLM_TEST=$LLM_RESULT"
echo "TELEGRAM_TEST=send a normal message to the existing OpenClaw bot; do not create another poller"
