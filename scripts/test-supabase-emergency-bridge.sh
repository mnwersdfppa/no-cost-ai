#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ENV="$HOME/.openclaw/secrets/pi-canonical-config.env"
LEGACY_ENV="$HOME/.openclaw/secrets/pi-work-queue.env"
ENV_FILE="${PI_BRIDGE_ENV:-$([[ -r "$DEFAULT_ENV" ]] && echo "$DEFAULT_ENV" || echo "$LEGACY_ENV")}" 
[[ -r "$ENV_FILE" ]] || { echo "BLOCKED=ENV_FILE_MISSING:$ENV_FILE" >&2; exit 20; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

BASE="${SUPABASE_URL:-https://dpllasnpfskyyyzebyal.supabase.co}"
TOKEN="${PI_ACCESS_TOKEN:-}"
[[ "$BASE" == 'https://dpllasnpfskyyyzebyal.supabase.co' ]] || { echo 'BLOCKED=CANONICAL_SUPABASE_URL_REQUIRED' >&2; exit 21; }
[[ ${#TOKEN} -ge 20 ]] || { echo 'BLOCKED=PI_ACCESS_TOKEN_REQUIRED' >&2; exit 22; }
BRIDGE_URL="${BASE%/}/functions/v1/emergency-bridge"
CONFIG_URL="${BASE%/}/functions/v1/canonical-client-config"

request() {
  local url="$1"
  local body="${2:-}"
  local correlation="emergency-smoke-$(date +%s)-$RANDOM"
  if [[ -n "$body" ]]; then
    curl -fsS --max-time 30 \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -H "X-Correlation-Id: $correlation" \
      --data "$body" \
      "$url"
  else
    curl -fsS --max-time 30 \
      -H "Authorization: Bearer $TOKEN" \
      -H "X-Correlation-Id: $correlation" \
      "$url"
  fi
}

CONFIG_JSON="$(request "$CONFIG_URL")"
printf '%s' "$CONFIG_JSON" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
assert obj.get("ok") is True
assert obj.get("config_version",0) >= 2
s=obj.get("supabase",{})
v=obj.get("vercel",{})
p=obj.get("policy",{})
assert s.get("project_ref") == "dpllasnpfskyyyzebyal"
assert s.get("url") == "https://dpllasnpfskyyyzebyal.supabase.co"
assert s.get("publishable_key_name") == "default"
assert s.get("publishable_key_type") == "publishable"
assert isinstance(s.get("publishable_key"),str) and s["publishable_key"].startswith("sb_publishable_")
assert s.get("legacy_anon_fallback_enabled") is False
assert s.get("server_secret_returned") is False
assert v.get("canonical_auth_mode") == "connected_connector"
assert v.get("team_id") == "team_sa2sEffAlVXK6b9lsweDm6QL"
assert v.get("raw_token_fallback_enabled") is False
assert v.get("deploy_enabled") is False
assert p.get("paid_api_fallback") is False
assert p.get("external_write_actions") is False
assert p.get("public_shell_execution") is False
assert p.get("telegram_single_poller_enforced") is True
assert p.get("raw_secret_values_returned") is False
print("CANONICAL_CONFIG_TEST=PASS")
'

STATUS_JSON="$(request "$BRIDGE_URL" '{"action":"status"}')"
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
assert obj.get("policy",{}).get("paid_api_fallback") is False
print("STATUS_TEST=PASS")
'

POLICY_JSON="$(request "$BRIDGE_URL" '{"action":"policy_check","integration":"openai","operation":"chat","execution_key":"smoke-openai-paid-policy-v2"}')"
printf '%s' "$POLICY_JSON" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
assert obj.get("ok") is True
assert obj.get("decision",{}).get("allowed") is False
assert obj.get("decision",{}).get("reason") == "paid_api_fallback_disabled"
print("PAID_FALLBACK_POLICY=PASS")
'

QUEUE_JSON="$(request "$BRIDGE_URL" '{"action":"queue_status"}')"
printf '%s' "$QUEUE_JSON" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
assert obj.get("ok") is True
assert obj.get("values_exposed") is False
print("QUEUE_STATUS_TEST=PASS")
'

echo 'RESULT=SUPABASE_EMERGENCY_BRIDGE_SMOKE_PASS'
echo 'SECRET_VALUES_PRINTED=NO'
