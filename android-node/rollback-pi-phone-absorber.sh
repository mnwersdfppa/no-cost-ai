#!/usr/bin/env bash
set -euo pipefail

if [[ "${OPENCLAW_SECURE_WRAPPER:-0}" != "1" ]]; then
  echo "BLOCKED=LEGACY_ROLLBACK_CORE_INTERNAL_ONLY"
  echo "NEXT=use rollback-pi-phone-absorber-secure.sh"
  exit 90
fi

# Reversible internal rollback core. The secure wrapper validates the immutable
# promotion record before invoking this file and verifies the restored model and
# Gateway health afterward.
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

PREVIOUS=""
if [[ -s "$ROOT/previous-primary.json" ]]; then
  PREVIOUS="$(python3 - "$ROOT/previous-primary.json" <<'PY'
import json,sys
try: data=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: data={}
value=data.get("previous_primary")
if isinstance(value,str) and value: print(value)
PY
)"
fi
if [[ -z "$PREVIOUS" || "$PREVIOUS" == "phone-codex-cli/gpt-5.6-sol" ]]; then
  echo "BLOCKED=SAFE_ROLLBACK_TARGET_REQUIRED"
  exit 91
fi
openclaw config set agents.defaults.model.primary "$PREVIOUS"

if command -v adb >/dev/null 2>&1; then
  adb forward --remove tcp:8022 >/dev/null 2>&1 || true
fi
openclaw mcp reload 2>/dev/null || true
openclaw gateway restart --safe 2>/dev/null || openclaw gateway restart 2>/dev/null || true

mkdir -p "$ROOT/logs"
cat > "$ROOT/logs/rollback-receipt.json" <<JSON
{
  "result": "rolled_back",
  "restored_primary": "$PREVIOUS",
  "phone_data": "unchanged",
  "pairing": "unchanged",
  "telegram": "unchanged"
}
JSON
chmod 600 "$ROOT/logs/rollback-receipt.json"

printf '%s\n' \
  'RESULT=ROLLED_BACK' \
  'REMOVED_MCP=android-phone-status,android-phone-inspect,android-phone-actions,phone-codex' \
  'PHONE_CODEX_PLUGIN=DISABLED' \
  "PREVIOUS_PRIMARY=$PREVIOUS" \
  'PHONE_DATA=UNCHANGED' \
  'OPENCLAW_PAIRING=UNCHANGED' \
  'TELEGRAM=UNCHANGED'
