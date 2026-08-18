#!/usr/bin/env bash
set -euo pipefail

CANDIDATES=(
  "${N8N_ENV_FILE:-}"
  "$HOME/.openclaw/secrets/n8n-owner.env"
  "$HOME/.openclaw/secrets/n8n-local.env"
  "$HOME/.openclaw/secrets/n8n.env"
)
ENV_FILE=""
for candidate in "${CANDIDATES[@]}"; do
  if [[ -n "$candidate" && -r "$candidate" ]]; then
    ENV_FILE="$candidate"
    break
  fi
done
[[ -n "$ENV_FILE" ]] || { echo 'BLOCKED=N8N_ENV_MISSING'; exit 20; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

BASE="${N8N_BASE_URL:-${N8N_URL:-${N8N_API_URL:-http://127.0.0.1:5678}}}"
KEY="${N8N_API_KEY:-${N8N_OWNER_API_KEY:-${N8N_TOKEN:-}}}"
BASE="${BASE%/}"
[[ "$BASE" =~ ^https?://[^[:space:]]+$ ]] || { echo 'BLOCKED=INVALID_N8N_BASE_URL'; exit 21; }

HEALTH_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/healthz" || true)"
if [[ "$HEALTH_STATUS" != "200" ]]; then
  echo "BLOCKED=N8N_HEALTH_FAILED:$HEALTH_STATUS"
  exit 22
fi
echo 'N8N_HEALTH=PASS'

[[ -n "$KEY" ]] || { echo "BLOCKED=N8N_API_KEY_ALIAS_NOT_FOUND:$ENV_FILE"; exit 23; }

WORKFLOWS="$(curl -fsS --max-time 20 \
  -H "X-N8N-API-KEY: $KEY" \
  -H 'Accept: application/json' \
  "$BASE/api/v1/workflows?limit=1")" || {
  echo 'BLOCKED=N8N_API_AUTH_OR_NETWORK_FAILED'
  exit 24
}

printf '%s' "$WORKFLOWS" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
rows=obj.get("data") if isinstance(obj,dict) else []
rows=rows if isinstance(rows,list) else []
safe=[{"id":r.get("id"),"name":r.get("name"),"active":r.get("active")} for r in rows[:1] if isinstance(r,dict)]
print(json.dumps({"authenticated":True,"sample":safe,"returned":len(rows),"secret_values_exposed":False},ensure_ascii=False))
'

if command -v n8n >/dev/null 2>&1; then
  echo 'N8N_AUDIT_AVAILABLE=YES'
  echo 'NEXT_OPTIONAL_LOCAL=n8n audit'
else
  echo 'N8N_AUDIT_AVAILABLE=CLI_NOT_IN_PATH'
fi

echo 'RESULT=N8N_READ_ONLY_VALIDATED'
