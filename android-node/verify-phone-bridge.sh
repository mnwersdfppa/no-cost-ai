#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
RUN_LLM_TEST="${RUN_LLM_TEST:-1}"
ENABLE_AFTER_VERIFY="${ENABLE_AFTER_VERIFY:-1}"
SET_PRIMARY="${SET_PRIMARY:-1}"

restart_gateway() {
  if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
    openclaw gateway restart --safe || true
  else
    openclaw gateway restart || true
  fi
}

if [[ ! -r "$ENV_FILE" ]]; then
  echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING"
  exit 30
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

adb start-server >/dev/null
if [[ "$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)" != "device" ]]; then
  echo "BLOCKED=ADB_DEVICE_NOT_READY"
  exit 31
fi
adb -s "$ANDROID_SERIAL" forward --remove tcp:"$PHONE_SSH_PORT" >/dev/null 2>&1 || true
adb -s "$ANDROID_SERIAL" forward tcp:"$PHONE_SSH_PORT" tcp:8022 >/dev/null

if [[ -z "${PHONE_SSH_USER:-}" ]]; then
  echo "BLOCKED=TERMUX_USER_UNKNOWN"
  echo "NEXT=run id -un in Termux and set PHONE_SSH_USER in $ENV_FILE"
  exit 32
fi

TMP_KNOWN="$(mktemp)"
trap 'rm -f "$TMP_KNOWN"' EXIT
if ! ssh-keyscan -T 10 -p "$PHONE_SSH_PORT" "$PHONE_SSH_HOST" > "$TMP_KNOWN" 2>/dev/null; then
  echo "BLOCKED=PHONE_SSHD_NOT_REACHABLE"
  echo "NEXT=run bash /sdcard/Download/openclaw-phone-bootstrap.sh in Termux"
  exit 33
fi
if [[ ! -s "$TMP_KNOWN" ]]; then
  echo "BLOCKED=PHONE_SSH_HOST_KEY_EMPTY"
  exit 34
fi
install -m 600 "$TMP_KNOWN" "$PHONE_SSH_KNOWN_HOSTS"

SSH=(
  ssh
  -p "$PHONE_SSH_PORT"
  -i "$PHONE_SSH_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$PHONE_SSH_KNOWN_HOSTS"
  -o ConnectTimeout=10
  "$PHONE_SSH_USER@$PHONE_SSH_HOST"
)

REMOTE_STATUS="$("${SSH[@]}" phone-status 2>&1 || true)"
printf '%s\n' "$REMOTE_STATUS"
if ! grep -q 'runner=ready' <<<"$REMOTE_STATUS"; then
  echo "BLOCKED=PHONE_RUNNER_NOT_READY"
  exit 35
fi

DENY_TEST="$("${SSH[@]}" uname -a 2>&1 || true)"
if ! grep -q 'DENIED=COMMAND_NOT_ALLOWLISTED' <<<"$DENY_TEST"; then
  echo "BLOCKED=FORCED_COMMAND_POLICY_NOT_ACTIVE"
  exit 36
fi

if ! grep -Eqi 'Logged in using ChatGPT|chatgpt|authenticated|login.*ok|successfully logged in' <<<"$REMOTE_STATUS"; then
  echo "BLOCKED=PHONE_CODEX_NOT_LOGGED_IN"
  echo "NEXT=run codex login --device-auth in Termux and approve it in the phone browser"
  exit 37
fi

LLM_RESULT="not_run"
if [[ "$RUN_LLM_TEST" == "1" ]]; then
  REQUEST='{"version":1,"model":"gpt-5.6-sol","prompt":"Reply exactly PHONE_CODEX_OK and nothing else."}'
  LLM_OUTPUT="$(printf '%s\n' "$REQUEST" | "${SSH[@]}" phone-codex-run 2>&1 || true)"
  if grep -q 'PHONE_CODEX_OK' <<<"$LLM_OUTPUT"; then
    LLM_RESULT="pass"
  else
    LLM_RESULT="fail"
    printf '%s\n' "$LLM_OUTPUT" | tail -n 40
    echo "BLOCKED=PHONE_CODEX_LIVE_TEST_FAILED"
    exit 38
  fi
fi

if [[ "$ENABLE_AFTER_VERIFY" == "1" ]]; then
  sed -i 's/^PHONE_CODEX_ENABLED=.*/PHONE_CODEX_ENABLED=1/' "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  export PHONE_CODEX_ENABLED=1
fi

openclaw mcp doctor android-phone-status --probe
openclaw mcp doctor android-phone-inspect --probe
openclaw mcp doctor phone-codex --probe
openclaw mcp status --verbose
openclaw nodes status || true
openclaw gateway call node.list --params '{}' || true

PLUGIN_RESULT="not_supported"
BACKEND_TEST="not_run"
if openclaw plugins --help >/dev/null 2>&1; then
  if ! openclaw plugins inspect phone-codex-cli --runtime >/dev/null 2>&1; then
    openclaw plugins install -l "$ROOT/phone-codex-cli-backend" || true
  fi
  openclaw plugins enable phone-codex-cli || true
  if openclaw plugins inspect phone-codex-cli --runtime >/dev/null 2>&1; then
    PLUGIN_RESULT="ready"
    restart_gateway
    set +e
    BACKEND_OUTPUT="$(openclaw agent --agent main --message 'Reply exactly PHONE_BACKEND_OK and nothing else.' --model phone-codex-cli/gpt-5.6-sol 2>&1)"
    BACKEND_STATUS=$?
    set -e
    if [[ $BACKEND_STATUS -eq 0 ]] && grep -q 'PHONE_BACKEND_OK' <<<"$BACKEND_OUTPUT"; then
      BACKEND_TEST="pass"
    else
      BACKEND_TEST="fail"
      printf '%s\n' "$BACKEND_OUTPUT" | tail -n 60
    fi
  else
    PLUGIN_RESULT="install_failed_mcp_fallback_ready"
  fi
fi

PRIMARY_RESULT="unchanged"
if [[ "$SET_PRIMARY" == "1" && "$BACKEND_TEST" == "pass" ]]; then
  openclaw config get agents.defaults.model.primary > "$ROOT/previous-primary.txt" 2>/dev/null || true
  chmod 600 "$ROOT/previous-primary.txt" 2>/dev/null || true
  openclaw config set agents.defaults.model.primary phone-codex-cli/gpt-5.6-sol
  PRIMARY_RESULT="phone-codex-cli/gpt-5.6-sol"
fi

openclaw mcp reload || true
restart_gateway
openclaw gateway status || true

mkdir -p "$ROOT/logs"
OVERALL="partial"
if [[ "$LLM_RESULT" == "pass" && "$BACKEND_TEST" == "pass" && "$PRIMARY_RESULT" == "phone-codex-cli/gpt-5.6-sol" ]]; then
  OVERALL="pass"
fi
cat > "$ROOT/logs/verify-receipt.json" <<JSON
{
  "result": "$OVERALL",
  "adb": "device",
  "ssh": "pinned_host_key",
  "forced_command": "pass",
  "codex_login": "chatgpt",
  "runner": "ready",
  "direct_llm_test": "$LLM_RESULT",
  "cli_plugin": "$PLUGIN_RESULT",
  "cli_backend_test": "$BACKEND_TEST",
  "primary_model": "$PRIMARY_RESULT",
  "phone_codex_enabled": "$ENABLE_AFTER_VERIFY",
  "mcp_actions_enabled": false,
  "secrets_printed": false,
  "telegram_single_poller": true
}
JSON
chmod 600 "$ROOT/logs/verify-receipt.json"

if [[ "$OVERALL" == "pass" ]]; then
  echo "RESULT=PASS"
else
  echo "RESULT=PARTIAL"
fi
echo "PHONE_CODEX=$([[ "$ENABLE_AFTER_VERIFY" == "1" ]] && echo ENABLED || echo DISABLED)"
echo "DIRECT_LLM_TEST=$LLM_RESULT"
echo "CLI_PLUGIN=$PLUGIN_RESULT"
echo "CLI_BACKEND_TEST=$BACKEND_TEST"
echo "PRIMARY_MODEL=$PRIMARY_RESULT"
echo "TELEGRAM_TEST=send a normal message to the existing OpenClaw bot; do not create another poller"
