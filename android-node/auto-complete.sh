#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
WAIT_SECONDS="${PHONE_AUTH_WAIT_SECONDS:-300}"

"$SCRIPT_DIR/install-channel-relay.sh"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING"
  exit 100
fi
set -a
source "$ENV_FILE"
set +a

try_verify() {
  RUN_LLM_TEST=1 ENABLE_AFTER_VERIFY=1 "$SCRIPT_DIR/verify-phone-bridge.sh" 2>&1
}

OUTPUT="$(try_verify || true)"
printf '%s\n' "$OUTPUT"

if grep -q 'RESULT=PASS' <<<"$OUTPUT"; then
  "$SCRIPT_DIR/enable-channel-relay.sh"
  "$SCRIPT_DIR/pair-openclaw-node.sh" || true
  echo "RESULT=READY_FOR_TELEGRAM_TEST"
  exit 0
fi

if grep -q 'BLOCKED=PHONE_CODEX_NOT_LOGGED_IN' <<<"$OUTPUT"; then
  adb -s "$ANDROID_SERIAL" shell am start -n com.termux/.app.TermuxActivity >/dev/null 2>&1 || true
  sleep 2
  adb -s "$ANDROID_SERIAL" shell input text 'codex%slogin%s--device-auth'
  adb -s "$ANDROID_SERIAL" shell input keyevent 66
  echo "ACTION=APPROVE_THE_CODE_SHOWN_IN_TERMUX_USING_THE_PHONE_BROWSER"
else
  echo "ACTION=RESOLVE_THE_BLOCKED_LINE_ABOVE; THE_FLOW_WILL_NOT_WEAKEN_AUTH_OR_INSTALL_UNVERIFIED_BINARIES"
fi

DEADLINE=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < DEADLINE )); do
  sleep 15
  OUTPUT="$(try_verify || true)"
  if grep -q 'RESULT=PASS' <<<"$OUTPUT"; then
    printf '%s\n' "$OUTPUT"
    "$SCRIPT_DIR/enable-channel-relay.sh"
    "$SCRIPT_DIR/pair-openclaw-node.sh" || true
    echo "RESULT=READY_FOR_TELEGRAM_TEST"
    exit 0
  fi
  if grep -qE 'BLOCKED=(ADB_DEVICE_NOT_READY|TERMUX_USER_UNKNOWN|PHONE_RUNNER_NOT_READY)' <<<"$OUTPUT"; then
    printf '%s\n' "$OUTPUT"
  fi
done

printf '%s\n' "$OUTPUT"
echo "BLOCKED=PHONE_AUTH_OR_RUNTIME_TIMEOUT"
echo "NEXT=finish the visible Termux device-auth approval, then run $SCRIPT_DIR/enable-channel-relay.sh"
exit 101
