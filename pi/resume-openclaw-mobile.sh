#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="${APPLY:-0}"
ENABLE_MATON="${ENABLE_MATON:-0}"
IMPORT_N8N="${IMPORT_N8N:-0}"

"$REPO_ROOT/pi/preflight-openclaw-mobile.sh"

if [[ "$APPLY" != "1" ]]; then
  echo 'RESULT=PREFLIGHT_ONLY'
  echo 'NEXT=rerun with APPLY=1 after checking the receipt'
  exit 0
fi

echo 'STAGE=HARDENED_ANDROID_BOOTSTRAP'
"$REPO_ROOT/android-node/bootstrap-all.sh"

ENV_FILE="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}/phone-bridge.env"
FINGERPRINT=""
if [[ -r "$ENV_FILE" ]]; then
  FINGERPRINT="$(sed -n 's/^PHONE_SSH_HOST_KEY_SHA256=//p' "$ENV_FILE" | tail -n1)"
fi
if [[ ! "$FINGERPRINT" =~ ^SHA256:[A-Za-z0-9+/=]+$ ]]; then
  echo 'RESULT=WAITING_FOR_PHONE_FINGERPRINT'
  echo 'NEXT_ON_PHONE=bash /sdcard/Download/openclaw-phone-bootstrap.sh'
  echo 'THEN_ON_PI=pi/set-phone-ssh-fingerprint.sh SHA256_VALUE_PRINTED_BY_PHONE'
  exit 30
fi

echo 'STAGE=T3_REAL_BRIDGE_VERIFY'
RUN_LLM_TEST=1 ENABLE_AFTER_VERIFY=1 SET_PRIMARY=1 "$REPO_ROOT/android-node/verify-phone-bridge.sh"

if [[ "$ENABLE_MATON" == "1" ]]; then
  echo 'STAGE=MATON_READONLY_PROBE'
  "$REPO_ROOT/pi/install-maton-readonly-mcp.sh"
fi

if [[ "$IMPORT_N8N" == "1" ]]; then
  echo 'STAGE=N8N_INACTIVE_IMPORT'
  "$REPO_ROOT/pi/import-n8n-openclaw-workflows-inactive.sh"
fi

echo 'RESULT=T3_COMPLETE_T4_PENDING'
echo 'NEXT=android-node/verify-telegram-t4.sh'
