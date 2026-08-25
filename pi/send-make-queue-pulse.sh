#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$ROOT/secrets}"
ENV_FILE="${MAKE_ENV_FILE:-$SECRETS/make.env}"

[[ -r "$ENV_FILE" ]] || { echo "BLOCKED=MAKE_ENV_MISSING:$ENV_FILE" >&2; exit 20; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

URL="${MAKE_WEBHOOK_URL:-${OPENCLAW_MAKE_WEBHOOK_URL:-}}"
TOKEN="${MAKE_WEBHOOK_TOKEN:-${MAKE_WEBHOOK_SIGNING_SECRET:-}}"
[[ "$URL" == https://* ]] || { echo 'BLOCKED=HTTPS_MAKE_WEBHOOK_URL_REQUIRED' >&2; exit 21; }
[[ -n "$TOKEN" ]] || { echo 'BLOCKED=MAKE_WEBHOOK_AUTH_TOKEN_REQUIRED' >&2; exit 22; }

EXECUTION_KEY="$(python3 - <<'PY'
import uuid; print(uuid.uuid4())
PY
)"
BODY="$(python3 - "$EXECUTION_KEY" <<'PY'
import datetime,json,sys
key=sys.argv[1]
print(json.dumps({
  'version':1,
  'execution_key':key,
  'action':'openclaw_queue_pulse',
  'requested_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
  'paid_model_allowed':False,
  'phone_write_allowed':False
},separators=(',',':')))
PY
)"

STATUS="$(python3 - "$URL" "$TOKEN" "$BODY" <<'PY'
import sys,urllib.request,urllib.error
url,token,body=sys.argv[1:]
req=urllib.request.Request(url,data=body.encode(),method='POST',headers={
  'Content-Type':'application/json',
  'X-OpenClaw-Token':token,
  'User-Agent':'openclaw-pi-queue-pulse/1'
})
try:
    with urllib.request.urlopen(req,timeout=30) as r:
        r.read(4096)
        print(r.status)
except urllib.error.HTTPError as e:
    e.read(4096)
    print(e.code)
PY
)"

case "$STATUS" in
  200|201|202|204)
    echo 'RESULT=MAKE_QUEUE_PULSE_ACCEPTED'
    echo "HTTP_STATUS=$STATUS"
    echo "EXECUTION_KEY=$EXECUTION_KEY"
    ;;
  *)
    echo 'RESULT=MAKE_QUEUE_PULSE_REJECTED'
    echo "HTTP_STATUS=$STATUS"
    exit 23
    ;;
esac
