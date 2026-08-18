#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${MAKE_ENV_FILE:-$HOME/.openclaw/secrets/make.env}"
[[ -r "$ENV_FILE" ]] || { echo "BLOCKED=MAKE_ENV_MISSING:$ENV_FILE"; exit 20; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

TOKEN="${MAKE_API_TOKEN:-${MAKE_API_KEY:-${MAKE_TOKEN:-}}}"
[[ -n "$TOKEN" ]] || { echo 'BLOCKED=MAKE_TOKEN_ALIAS_NOT_FOUND'; exit 21; }

ZONE="${MAKE_ZONE:-eu1}"
[[ "$ZONE" =~ ^[a-z0-9-]+$ ]] || { echo 'BLOCKED=INVALID_MAKE_ZONE'; exit 22; }
BASE="https://${ZONE}.make.com/api/v2"

safe_get() {
  local path="$1"
  curl -fsS --max-time 20 \
    -H "Authorization: Token $TOKEN" \
    -H 'Accept: application/json' \
    "$BASE$path"
}

USER_JSON="$(safe_get '/users/me?cols[]=id&cols[]=name&cols[]=timezoneId&cols[]=userOrganizationRoles&cols[]=userTeamRoles')" || {
  echo 'BLOCKED=MAKE_AUTH_OR_NETWORK_FAILED'
  exit 23
}

printf '%s' "$USER_JSON" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
user=obj.get("user") if isinstance(obj.get("user"),dict) else obj
safe={
  "authenticated": True,
  "user_id": user.get("id"),
  "name": user.get("name"),
  "timezone_id": user.get("timezoneId"),
  "organization_roles": len(user.get("userOrganizationRoles") or []),
  "team_roles": len(user.get("userTeamRoles") or []),
  "secret_values_exposed": False,
}
print(json.dumps(safe,ensure_ascii=False))
'

ORG_JSON="$(safe_get '/organizations?cols[]=id&cols[]=name&cols[]=timezoneId')" || {
  echo 'BLOCKED=MAKE_ORGANIZATIONS_READ_FAILED'
  exit 24
}
printf '%s' "$ORG_JSON" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
rows=obj.get("organizations") or []
print(json.dumps({"organizations":[{"id":r.get("id"),"name":r.get("name"),"timezone_id":r.get("timezoneId")} for r in rows],"count":len(rows)},ensure_ascii=False))
'

if [[ -n "${MAKE_TEAM_ID:-}" ]]; then
  [[ "$MAKE_TEAM_ID" =~ ^[0-9]+$ ]] || { echo 'BLOCKED=INVALID_MAKE_TEAM_ID'; exit 25; }
  SCENARIO_JSON="$(safe_get "/scenarios?teamId=$MAKE_TEAM_ID&cols[]=id&cols[]=name&cols[]=isActive")" || {
    echo 'BLOCKED=MAKE_SCENARIOS_READ_FAILED'
    exit 26
  }
  printf '%s' "$SCENARIO_JSON" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
rows=obj.get("scenarios") or []
print(json.dumps({"scenarios":[{"id":r.get("id"),"name":r.get("name"),"active":r.get("isActive")} for r in rows],"count":len(rows)},ensure_ascii=False))
'
else
  echo 'MAKE_SCENARIOS=SKIPPED_SET_MAKE_TEAM_ID'
fi

echo 'RESULT=MAKE_READ_ONLY_VALIDATED'
