#!/usr/bin/env bash
set -euo pipefail

SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="${PHONE_BRIDGE_ENV:-$SECRETS/phone-bridge.env}"
[[ -r "$ENV_FILE" ]] || { echo "PHONE_CODEX_BACKEND_ERROR: bridge env missing" >&2; exit 50; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

MODEL="${PHONE_CODEX_MODEL:-gpt-5.6-sol}"
while (($#)); do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || { echo "PHONE_CODEX_BACKEND_ERROR: missing model" >&2; exit 51; }
      MODEL="$2"; shift 2 ;;
    *)
      echo "PHONE_CODEX_BACKEND_ERROR: unsupported argument" >&2
      exit 52 ;;
  esac
done

case "$MODEL" in
  gpt-5.6|gpt-5.6-sol) ;;
  *) echo "PHONE_CODEX_BACKEND_ERROR: model denied" >&2; exit 53 ;;
esac

[[ "${PHONE_CODEX_ENABLED:-0}" == "1" ]] || {
  echo "PHONE_CODEX_BACKEND_ERROR: route disabled until verification passes" >&2
  exit 54
}

: "${PHONE_SSH_USER:?PHONE_SSH_USER is required}"
: "${PHONE_SSH_KEY:?PHONE_SSH_KEY is required}"
: "${PHONE_SSH_KNOWN_HOSTS:?PHONE_SSH_KNOWN_HOSTS is required}"
[[ -r "$PHONE_SSH_KEY" && -r "$PHONE_SSH_KNOWN_HOSTS" ]] || {
  echo "PHONE_CODEX_BACKEND_ERROR: SSH trust material missing" >&2
  exit 55
}

MAX_PROMPT="${PHONE_CODEX_MAX_PROMPT:-12000}"
if ! PROMPT="$(python3 -c '
import sys
limit=int(sys.argv[1])
data=sys.stdin.read(limit+1)
if not data:
    print("prompt is empty", file=sys.stderr)
    raise SystemExit(2)
if len(data)>limit:
    print("prompt exceeds limit", file=sys.stderr)
    raise SystemExit(3)
sys.stdout.write(data)
' "$MAX_PROMPT")"; then
  echo "PHONE_CODEX_BACKEND_ERROR: prompt missing or too long" >&2
  exit 62
fi

REQUEST="$(printf '%s' "$PROMPT" | python3 -c '
import json,sys
model=sys.argv[1]
prompt=sys.stdin.read()
print(json.dumps({"version":1,"model":model,"prompt":prompt},ensure_ascii=False))
' "$MODEL")"
unset PROMPT

OUT="$(mktemp)"
ERR="$(mktemp)"
cleanup() { rm -f "$OUT" "$ERR"; }
trap cleanup EXIT

set +e
printf '%s\n' "$REQUEST" | env \
  -u OPENAI_API_KEY \
  -u OPENAI_BASE_URL \
  -u OPENAI_ORG_ID \
  -u OPENAI_PROJECT_ID \
  ssh \
    -p "${PHONE_SSH_PORT:-8022}" \
    -i "$PHONE_SSH_KEY" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$PHONE_SSH_KNOWN_HOSTS" \
    -o ConnectTimeout=10 \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2 \
    "$PHONE_SSH_USER@${PHONE_SSH_HOST:-127.0.0.1}" \
    phone-codex-run >"$OUT" 2>"$ERR"
SSH_STATUS=$?
set -e
unset REQUEST

python3 - "$OUT" "$ERR" "$SSH_STATUS" <<'PY'
import json,sys
out_path,err_path,status=sys.argv[1],sys.argv[2],int(sys.argv[3])
out=open(out_path,encoding='utf-8',errors='replace').read()
err=open(err_path,encoding='utf-8',errors='replace').read()
final=''
fatal=''
for raw in out.splitlines():
    line=raw.strip()
    if not line:
        continue
    try:
        event=json.loads(line)
    except Exception:
        continue
    typ=str(event.get('type',''))
    if typ in {'error','turn.failed'}:
        fatal=event.get('message') or (event.get('error') or {}).get('message') or line
    item=event.get('item') or ((event.get('data') or {}).get('item') if isinstance(event.get('data'),dict) else None)
    if isinstance(item,dict) and item.get('type')=='agent_message' and isinstance(item.get('text'),str):
        final=item['text']
    if typ=='turn.completed' and isinstance(event.get('final_output'),str):
        final=event['final_output']
if not final and status==0:
    final=out.strip()
if status!=0 or fatal or not final:
    detail=fatal or err.strip() or out.strip() or f'ssh exit {status}'
    print('PHONE_CODEX_BACKEND_ERROR: '+detail[:2000],file=sys.stderr)
    raise SystemExit(status or 70)
print(final)
PY
