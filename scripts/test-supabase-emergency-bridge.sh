#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${PI_WORK_QUEUE_ENV:-$HOME/.openclaw/secrets/pi-work-queue.env}"
[[ -r "$ENV_FILE" ]] || { echo "BLOCKED=ENV_FILE_MISSING:$ENV_FILE" >&2; exit 20; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

BASE="${SUPABASE_URL:-https://dpllasnpfskyyyzebyal.supabase.co}"
TOKEN="${PI_ACCESS_TOKEN:-}"
[[ "$BASE" == https://* ]] || { echo 'BLOCKED=HTTPS_SUPABASE_URL_REQUIRED' >&2; exit 21; }
[[ ${#TOKEN} -ge 20 ]] || { echo 'BLOCKED=PI_ACCESS_TOKEN_REQUIRED' >&2; exit 22; }
URL="${BASE%/}/functions/v1/emergency-bridge"

request() {
  local body="$1"
  curl -fsS --max-time 30 \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -H "X-Correlation-Id: emergency-smoke-$(date +%s)" \
    --data "$body" \
    "$URL"
}

STATUS_JSON="$(request '{"action":"status"}')"
printf '%s' "$STATUS_JSON" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
assert obj.get("ok") is True
assert obj.get("values_exposed") is False
assert obj.get("secrets_returned") is False
controls={row["control_key"]:row["enabled"] for row in obj.get("controls",[])}
assert controls.get("paid_api_fallback") is False
assert controls.get("public_shell_execution") is False
assert controls.get("telegram_single_poller_enforced") is True
print("STATUS_TEST=PASS")
'

POLICY_JSON="$(request '{"action":"policy_check","integration":"openai","operation":"chat","execution_key":"smoke-openai-paid-policy-v1"}')"
printf '%s' "$POLICY_JSON" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
assert obj.get("ok") is True
assert obj.get("decision",{}).get("allowed") is False
assert obj.get("decision",{}).get("reason") == "paid_api_fallback_disabled"
print("PAID_FALLBACK_POLICY=PASS")
'

QUEUE_JSON="$(request '{"action":"queue_status"}')"
printf '%s' "$QUEUE_JSON" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
assert obj.get("ok") is True
assert obj.get("values_exposed") is False
print("QUEUE_STATUS_TEST=PASS")
'

echo 'RESULT=SUPABASE_EMERGENCY_BRIDGE_SMOKE_PASS'
echo 'SECRET_VALUES_PRINTED=NO'
