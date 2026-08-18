#!/usr/bin/env bash
set -euo pipefail

# Reversible rollback. It changes only OpenClaw registrations/model selection and
# the local USB forward. Phone data, apps, pairings, auth files and Telegram
# configuration are not deleted.

ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
for name in \
  android-phone-status \
  android-phone-inspect \
  android-phone-actions \
  android-phone-read \
  android-phone-write \
  phone-codex; do
  openclaw mcp unset "$name" 2>/dev/null || true
done

if openclaw plugins --help >/dev/null 2>&1; then
  openclaw plugins disable phone-codex-cli 2>/dev/null || true
fi

if [[ -s "$ROOT/previous-primary.txt" ]]; then
  PREVIOUS="$(python3 - "$ROOT/previous-primary.txt" <<'PY'
import json,sys
raw=open(sys.argv[1],encoding='utf-8').read().strip()
try:
    value=json.loads(raw)
except Exception:
    value=raw
if isinstance(value,str) and value:
    print(value)
PY
)"
  if [[ -n "$PREVIOUS" ]]; then
    openclaw config set agents.defaults.model.primary "$PREVIOUS" || true
  fi
fi

if command -v adb >/dev/null 2>&1; then
  adb forward --remove tcp:8022 >/dev/null 2>&1 || true
fi
openclaw mcp reload 2>/dev/null || true
openclaw gateway restart --safe 2>/dev/null || openclaw gateway restart 2>/dev/null || true

printf '%s\n' \
  'RESULT=ROLLED_BACK' \
  'REMOVED_MCP=android-phone-status,android-phone-inspect,android-phone-actions,phone-codex' \
  'PHONE_CODEX_PLUGIN=DISABLED' \
  'PREVIOUS_PRIMARY=RESTORED_IF_RECORDED' \
  'PHONE_DATA=UNCHANGED' \
  'OPENCLAW_PAIRING=UNCHANGED' \
  'TELEGRAM=UNCHANGED'
