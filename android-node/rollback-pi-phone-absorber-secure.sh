#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$SCRIPT_DIR/rollback-pi-phone-absorber.sh"
ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
PROMOTION_RECORD="$ROOT/previous-primary.json"
RECEIPT="$ROOT/logs/rollback-receipt.json"
TARGET_PRIMARY="phone-codex-cli/gpt-5.6-sol"

normalize_config_string() {
  python3 -c '
import json,sys
raw=sys.stdin.read().strip()
try: value=json.loads(raw)
except Exception: value=raw
if isinstance(value,str): print(value)
'
}

[[ -r "$PROMOTION_RECORD" ]] || { echo "BLOCKED=PROMOTION_ROLLBACK_RECORD_MISSING"; exit 111; }
PREVIOUS_PRIMARY="$(python3 - "$PROMOTION_RECORD" "$TARGET_PRIMARY" <<'PY'
import json,sys
path,target=sys.argv[1:]
try: data=json.load(open(path,encoding='utf-8'))
except Exception: raise SystemExit('BLOCKED=PROMOTION_ROLLBACK_RECORD_INVALID')
previous=data.get('previous_primary')
recorded_target=data.get('target_primary')
if not isinstance(previous,str) or not previous.strip() or previous==target or recorded_target!=target:
    raise SystemExit('BLOCKED=PROMOTION_ROLLBACK_RECORD_INVALID')
print(previous)
PY
)"

bash "$CORE"

RESTORED="$(openclaw config get agents.defaults.model.primary 2>/dev/null | normalize_config_string || true)"
if [[ "$RESTORED" != "$PREVIOUS_PRIMARY" ]]; then
  echo "BLOCKED=ROLLBACK_PRIMARY_NOT_RESTORED"
  echo "EXPECTED=$PREVIOUS_PRIMARY"
  echo "ACTUAL=${RESTORED:-empty}"
  exit 112
fi
openclaw gateway status

mkdir -p "$ROOT/logs"
python3 - "$RECEIPT" "$PREVIOUS_PRIMARY" <<'PY'
import json,os,sys,tempfile
path,restored=sys.argv[1:]
data={
  'result':'rolled_back_verified',
  'restored_primary':restored,
  'gateway_health':'pass',
  'phone_data':'unchanged',
  'pairing':'unchanged',
  'telegram':'unchanged',
}
directory=os.path.dirname(path)
fd,tmp=tempfile.mkstemp(prefix='.rollback-receipt.',dir=directory,text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as handle:
        json.dump(data,handle,ensure_ascii=False,indent=2)
        handle.flush(); os.fsync(handle.fileno())
    os.chmod(tmp,0o600)
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY

echo "RESULT=ROLLED_BACK_VERIFIED"
echo "RESTORED_PRIMARY=$PREVIOUS_PRIMARY"
echo "GATEWAY=PASS"
