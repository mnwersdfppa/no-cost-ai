#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$ROOT/secrets}"
ENV_FILE="${N8N_ENV_FILE:-$SECRETS/n8n.env}"
FACTORY_ROOT="${CONTENT_FACTORY_ROOT:-$HOME/content-factory-n8n-1000}"
API_PATH="${N8N_API_PATH:-/api/v1}"

[[ -r "$ENV_FILE" ]] || { echo "BLOCKED=N8N_ENV_MISSING:$ENV_FILE" >&2; exit 20; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

BASE="${N8N_BASE_URL:-${N8N_URL:-}}"
KEY="${N8N_API_KEY:-${N8N_OWNER_API_KEY:-}}"
[[ "$BASE" == http://127.0.0.1* || "$BASE" == http://localhost* || "$BASE" == https://* ]] || { echo 'BLOCKED=N8N_BASE_URL_REQUIRED' >&2; exit 21; }
[[ -n "$KEY" ]] || { echo 'BLOCKED=N8N_API_KEY_REQUIRED' >&2; exit 22; }
BASE="${BASE%/}"
API="${BASE}${API_PATH}"

for file in \
  "$FACTORY_ROOT/workflows/openclaw_pi_queue_worker.json" \
  "$FACTORY_ROOT/workflows/openclaw_make_webhook_pulse.json"; do
  [[ -r "$file" ]] || { echo "BLOCKED=WORKFLOW_FILE_MISSING:$file" >&2; exit 23; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$API" "$KEY" <<'PY'
import json,sys,urllib.request,urllib.error
api,key=sys.argv[1:]
req=urllib.request.Request(api+'/workflows?limit=1',headers={'X-N8N-API-KEY':key,'Accept':'application/json'})
try:
    with urllib.request.urlopen(req,timeout=20) as r:
        data=json.load(r)
except urllib.error.HTTPError as e:
    raise SystemExit(f'BLOCKED=N8N_API_HTTP_{e.code}')
print('N8N_API=REACHABLE')
PY

import_one() {
  local source="$1"
  local prepared="$TMP/$(basename "$source")"
  python3 - "$source" "$prepared" <<'PY'
import json,sys
src,dst=sys.argv[1:]
data=json.load(open(src,encoding='utf-8'))
for key in ('id','versionId','updatedAt','createdAt','triggerCount','shared','tags'):
    data.pop(key,None)
data['active']=False
for node in data.get('nodes',[]):
    creds=node.get('credentials')
    if isinstance(creds,dict):
        # Placeholder credentials are intentionally removed; operator binds a real
        # credential inside n8n before activation.
        node.pop('credentials',None)
json.dump(data,open(dst,'w',encoding='utf-8'),ensure_ascii=False,separators=(',',':'))
PY

  python3 - "$API" "$KEY" "$prepared" <<'PY'
import json,sys,urllib.parse,urllib.request,urllib.error
api,key,path=sys.argv[1:]
payload=json.load(open(path,encoding='utf-8'))
name=payload.get('name','')
query=urllib.parse.urlencode({'limit':100})
req=urllib.request.Request(api+'/workflows?'+query,headers={'X-N8N-API-KEY':key,'Accept':'application/json'})
with urllib.request.urlopen(req,timeout=20) as r: listing=json.load(r)
items=listing.get('data',listing if isinstance(listing,list) else [])
for item in items:
    if isinstance(item,dict) and item.get('name')==name:
        print(f'SKIP_EXISTING={name} id={item.get("id","")}')
        raise SystemExit(0)
body=json.dumps(payload,separators=(',',':')).encode()
req=urllib.request.Request(api+'/workflows',data=body,method='POST',headers={'X-N8N-API-KEY':key,'Content-Type':'application/json','Accept':'application/json'})
try:
    with urllib.request.urlopen(req,timeout=30) as r: created=json.load(r)
except urllib.error.HTTPError as e:
    detail=e.read().decode('utf-8',errors='replace')[:500]
    raise SystemExit(f'BLOCKED=N8N_IMPORT_HTTP_{e.code}:{detail}')
print(f'IMPORTED_INACTIVE={name} id={created.get("id","")}')
PY
}

import_one "$FACTORY_ROOT/workflows/openclaw_pi_queue_worker.json"
import_one "$FACTORY_ROOT/workflows/openclaw_make_webhook_pulse.json"

echo 'RESULT=N8N_WORKFLOWS_IMPORTED_INACTIVE_OR_ALREADY_PRESENT'
echo 'ACTIVATED=NO'
echo 'NEXT=bind Header Auth credential and run negative authentication tests before activation'
