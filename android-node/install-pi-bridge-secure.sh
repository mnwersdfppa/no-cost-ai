#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
AUTO_TYPE_TERMUX="${AUTO_TYPE_TERMUX:-0}"

AUTO_TYPE_TERMUX=0 "$SCRIPT_DIR/install-pi-bridge.sh"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING_AFTER_BASE_INSTALL"
  exit 91
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
  echo "BLOCKED=ANDROID_SERIAL_MISSING_AFTER_BASE_INSTALL"
  exit 92
fi
if [[ "$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)" != "device" ]]; then
  echo "BLOCKED=ADB_DEVICE_NOT_READY_FOR_SECURE_PHONE_PACKET"
  exit 93
fi

adb -s "$ANDROID_SERIAL" push "$SCRIPT_DIR/phone-termux-bootstrap.sh" /sdcard/Download/openclaw-phone-bootstrap-core.sh >/dev/null
adb -s "$ANDROID_SERIAL" push "$SCRIPT_DIR/install-verified-codex-termux.sh" /sdcard/Download/openclaw-install-codex-verified.sh >/dev/null
adb -s "$ANDROID_SERIAL" push "$SCRIPT_DIR/phone-termux-bootstrap-secure.sh" /sdcard/Download/openclaw-phone-bootstrap.sh >/dev/null

if [[ "$AUTO_TYPE_TERMUX" == "1" ]]; then
  adb -s "$ANDROID_SERIAL" shell am start -n com.termux/.app.TermuxActivity >/dev/null 2>&1 || true
  sleep 2
  adb -s "$ANDROID_SERIAL" shell input text 'bash%s/sdcard/Download/openclaw-phone-bootstrap.sh'
  adb -s "$ANDROID_SERIAL" shell input keyevent 66
fi

printf '%s\n' \
  'RESULT=PI_BRIDGE_SECURE_PACKET_PREPARED' \
  'CODEX_PACKAGE=VERSION_INTEGRITY_SHASUM_PINNED' \
  'PI_PUBLIC_KEY=ONE_ED25519_RECORD_REQUIRED' \
  'PHONE_BOOTSTRAP=bash /sdcard/Download/openclaw-phone-bootstrap.sh'
