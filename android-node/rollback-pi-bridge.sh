#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
DELETE_FILES="${DELETE_FILES:-0}"

openclaw mcp unset android-phone-read || true
openclaw mcp unset android-phone-write || true
openclaw mcp unset phone-codex || true
if [[ -r "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
  adb -s "${ANDROID_SERIAL:-}" forward --remove tcp:"${PHONE_SSH_PORT:-8022}" 2>/dev/null || true
fi
if [[ "$DELETE_FILES" == "1" ]]; then
  rm -rf "$ROOT"
fi
if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
  openclaw gateway restart --safe || true
else
  openclaw gateway restart || true
fi
echo "RESULT=PHONE_BRIDGE_ROLLED_BACK"
echo "FILES_DELETED=$DELETE_FILES"
