#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$ROOT/secrets}"
SOURCE_ENV="${SUPABASE_ENV_FILE:-$SECRETS/supabase.env}"
OUTPUT_ENV="${CANONICAL_CONFIG_ENV:-$SECRETS/supabase-canonical-client.env}"
PROJECT_URL="${SUPABASE_URL:-https://dpllasnpfskyyyzebyal.supabase.co}"
ENDPOINT="$PROJECT_URL/functions/v1/canonical-client-config"

for command in curl python3 mktemp; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "BLOCKED=MISSING_COMMAND:$command" >&2
    exit 20
  }
done

mkdir -p "$SECRETS"
chmod 700 "$ROOT" "$SECRETS" 2>/dev/null || true

if [[ -r "$SOURCE_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$SOURCE_ENV"
  set +a
fi

TOKEN="${PI_ACCESS_TOKEN:-${SUPABASE_ACCESS_TOKEN:-${SUPABASE_JWT:-${OPENCLAW_PI_JWT:-}}}}"
[[ -n "$TOKEN" ]] || {
  echo "BLOCKED=PI_ACCESS_TOKEN_MISSING" >&2
  echo "NEXT=place a current short-lived Pi user JWT in $SOURCE_ENV as PI_ACCESS_TOKEN" >&2
  exit 21
}

CORRELATION_ID="canonical-$(date -u +%Y%m%dT%H%M%SZ)-$$"
TMP_JSON="$(mktemp)"
TMP_ENV="$(mktemp "$SECRETS/.supabase-canonical-client.XXXXXX")"
cleanup() { rm -f "$TMP_JSON" "$TMP_ENV"; }
trap cleanup EXIT

HTTP_STATUS="$(curl -sS --fail-with-body --max-time 30 \
  -o "$TMP_JSON" \
  -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/json' \
  -H "X-Correlation-ID: $CORRELATION_ID" \
  "$ENDPOINT" || true)"

if [[ "$HTTP_STATUS" != "200" ]]; then
  ERROR_CODE="$(python3 - "$TMP_JSON" <<'PY'
import json,sys
try: data=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception: data={}
value=data.get('error')
print(value if isinstance(value,str) else 'request_failed')
PY
)"
  echo "BLOCKED=CANONICAL_CONFIG_HTTP_${HTTP_STATUS:-000}:$ERROR_CODE" >&2
  exit 22
fi

python3 - "$TMP_JSON" "$TMP_ENV" <<'PY'
import json,os,shlex,sys
source,target=sys.argv[1:]
data=json.load(open(source,encoding='utf-8'))
if data.get('ok') is not True:
    raise SystemExit('BLOCKED=CANONICAL_CONFIG_NOT_OK')
supa=data.get('supabase') if isinstance(data.get('supabase'),dict) else {}
vercel=data.get('vercel') if isinstance(data.get('vercel'),dict) else {}
policy=data.get('policy') if isinstance(data.get('policy'),dict) else {}
url=supa.get('url')
key=supa.get('publishable_key')
if not isinstance(url,str) or not url.startswith('https://'):
    raise SystemExit('BLOCKED=CANONICAL_SUPABASE_URL_INVALID')
if not isinstance(key,str) or not key.startswith('sb_publishable_'):
    raise SystemExit('BLOCKED=CANONICAL_PUBLISHABLE_KEY_INVALID')
if data.get('server_secret_returned') is not False or data.get('raw_vercel_token_returned') is not False:
    raise SystemExit('BLOCKED=SERVER_SECRET_BOUNDARY_FAILED')
endpoints=supa.get('endpoints') if isinstance(supa.get('endpoints'),dict) else {}
values={
    'SUPABASE_URL':url,
    'SUPABASE_PUBLISHABLE_KEY':key,
    'SUPABASE_PUBLISHABLE_KEY_NAME':str(supa.get('publishable_key_name') or 'default'),
    'SUPABASE_EMERGENCY_BRIDGE_URL':str(endpoints.get('emergency_bridge') or ''),
    'SUPABASE_CREDENTIAL_READINESS_URL':str(endpoints.get('credential_readiness') or ''),
    'SUPABASE_PI_WORK_QUEUE_URL':str(endpoints.get('pi_work_queue') or ''),
    'SUPABASE_TOKEN_GATEWAY_URL':str(endpoints.get('token_gateway') or ''),
    'VERCEL_CANONICAL_TEAM_ID':str(vercel.get('team_id') or ''),
    'VERCEL_CANONICAL_TEAM_SLUG':str(vercel.get('team_slug') or ''),
    'VERCEL_DEPLOYMENT_ENABLED':'1' if vercel.get('deployment_enabled') is True else '0',
    'PAID_API_FALLBACK':'1' if policy.get('paid_api_fallback') is True else '0',
    'TELEGRAM_SINGLE_POLLER_ENFORCED':'1' if policy.get('telegram_single_poller_enforced') is True else '0',
}
with open(target,'w',encoding='utf-8') as handle:
    for name,value in values.items():
        handle.write(f'{name}={shlex.quote(value)}\n')
    handle.flush(); os.fsync(handle.fileno())
os.chmod(target,0o600)
PY

mv -f "$TMP_ENV" "$OUTPUT_ENV"
chmod 600 "$OUTPUT_ENV"
trap - EXIT
rm -f "$TMP_JSON"

echo 'RESULT=CANONICAL_CLIENT_CONFIG_UPDATED'
echo "OUTPUT_ENV=$OUTPUT_ENV"
echo 'SUPABASE_KEY=MODERN_DEFAULT_PUBLISHABLE'
echo 'SUPABASE_SERVER_SECRET_RETURNED=NO'
echo 'VERCEL_RAW_TOKEN_RETURNED=NO'
echo 'PAID_API_FALLBACK=OFF'
