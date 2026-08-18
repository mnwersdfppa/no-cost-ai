#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android-node"
PI_DIR="$ROOT_DIR/pi"
ENABLE_QUEUE_TIMER="${ENABLE_QUEUE_TIMER:-0}"
REPORT_DIR="${OPENCLAW_MOBILE_REPORT_DIR:-$HOME/.openclaw/mobile-bootstrap}"
REPORT="$REPORT_DIR/last-run.txt"

mkdir -p "$REPORT_DIR"
chmod 700 "$REPORT_DIR"
exec > >(tee "$REPORT") 2>&1
chmod 600 "$REPORT"

run_optional() {
  local label="$1"
  shift
  echo "=== $label ==="
  set +e
  "$@"
  local status=$?
  set -e
  echo "${label// /_}_EXIT=$status"
  return 0
}

command -v openclaw >/dev/null 2>&1 || { echo 'BLOCKED=OPENCLAW_NOT_FOUND'; exit 20; }
command -v git >/dev/null 2>&1 || { echo 'BLOCKED=GIT_NOT_FOUND'; exit 21; }

echo 'MODE=SAFE_READ_ONLY_FIRST'
echo 'ROOT_JAILBREAK=OFF'
echo 'PAID_OPENAI_AUTOMATIC_FALLBACK=OFF'
echo 'SECOND_TELEGRAM_POLLER=OFF'
echo "ROOT_DIR=$ROOT_DIR"

git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null
printf 'SOURCE_COMMIT=%s\n' "$(git -C "$ROOT_DIR" rev-parse HEAD)"

run_optional 'ANDROID_READ_ONLY_INSTALL' "$ANDROID_DIR/install-pi-android-node.sh"
run_optional 'MATON_READ_ONLY_OAUTH_STAGE' "$PI_DIR/install-maton-readonly-oauth.sh"

if [[ -r "$HOME/.openclaw/secrets/n8n-owner.env" || -r "$HOME/.openclaw/secrets/n8n-local.env" || -r "$HOME/.openclaw/secrets/n8n.env" ]]; then
  run_optional 'N8N_READ_ONLY_PROBE' "$PI_DIR/check-n8n-readonly.sh"
else
  echo 'N8N_READ_ONLY_PROBE=SKIPPED_ENV_NOT_FOUND'
fi

if [[ -r "$HOME/.openclaw/secrets/make.env" ]]; then
  run_optional 'MAKE_READ_ONLY_PROBE' "$PI_DIR/check-make-readonly.sh"
else
  echo 'MAKE_READ_ONLY_PROBE=SKIPPED_ENV_NOT_FOUND'
fi

QUEUE_ENV="$HOME/.openclaw/secrets/pi-work-queue.env"
if [[ "$ENABLE_QUEUE_TIMER" == "1" ]]; then
  if [[ -r "$QUEUE_ENV" ]] && grep -Eq '^PI_ACCESS_TOKEN=.{20,}$' "$QUEUE_ENV"; then
    run_optional 'WORK_QUEUE_TIMER_INSTALL' "$PI_DIR/install-work-queue-timer.sh"
  else
    echo "WORK_QUEUE_TIMER=BLOCKED_CURRENT_PI_JWT_REQUIRED:$QUEUE_ENV"
  fi
else
  echo 'WORK_QUEUE_TIMER=PREPARED_NOT_ENABLED'
fi

run_optional 'OPENCLAW_STATUS' openclaw status
run_optional 'OPENCLAW_GATEWAY_STATUS' openclaw gateway status
run_optional 'OPENCLAW_MCP_STATUS' openclaw mcp status --verbose
run_optional 'OPENCLAW_DEVICE_STATUS' openclaw devices list
run_optional 'OPENCLAW_NODE_STATUS' openclaw nodes status

echo 'RESULT=PRESTAGED_PHYSICAL_GATES_MAY_REMAIN'
echo 'NEXT_MANUAL_ORDER=USB_DEBUG_APPROVAL>ANDROID_SETUP_CODE>MATON_BROWSER_OAUTH>TELEGRAM_CORRELATION_TEST'
echo "REPORT=$REPORT"
