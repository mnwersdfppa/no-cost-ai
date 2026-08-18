#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$SCRIPT_DIR/verify-phone-bridge.sh"
ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
RECEIPT="$ROOT/logs/verify-receipt.json"
PROMOTION_RECORD="$ROOT/previous-primary.json"
TARGET_PRIMARY="phone-codex-cli/gpt-5.6-sol"
SET_PRIMARY="${SET_PRIMARY:-1}"
RUN_LLM_TEST="${RUN_LLM_TEST:-1}"
ENABLE_AFTER_VERIFY="${ENABLE_AFTER_VERIFY:-1}"

normalize_config_string() {
  python3 -c '
import json,sys
raw=sys.stdin.read().strip()
try: value=json.loads(raw)
except Exception: value=raw
if isinstance(value,str): print(value)
'
}

restart_gateway() {
  if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
    openclaw gateway restart --safe
  else
    openclaw gateway restart
  fi
}

[[ -r "$ENV_FILE" ]] || { echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING"; exit 101; }
[[ -x "$CORE" || -r "$CORE" ]] || { echo "BLOCKED=CORE_VERIFIER_MISSING"; exit 102; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

python3 - "$PHONE_SSH_KNOWN_HOSTS" "$PHONE_SSH_HOST_KEY_SHA256" <<'PY'
import subprocess,sys
path,expected=sys.argv[1:]
try:
    lines=[line.strip() for line in open(path,encoding='utf-8',errors='strict') if line.strip() and not line.lstrip().startswith('#')]
except Exception:
    raise SystemExit('BLOCKED=PINNED_SSH_HOST_KEY_UNREADABLE')
if len(lines)!=1:
    raise SystemExit('BLOCKED=PINNED_SSH_HOST_KEY_RECORD_COUNT_INVALID')
parts=lines[0].split()
if len(parts)<3 or parts[1] != 'ssh-ed25519':
    raise SystemExit('BLOCKED=PINNED_SSH_HOST_KEY_FORMAT_INVALID')
proc=subprocess.run(['ssh-keygen','-lf',path,'-E','sha256'],capture_output=True,text=True,check=False)
out=[line for line in proc.stdout.splitlines() if line.strip()]
if proc.returncode!=0 or len(out)!=1:
    raise SystemExit('BLOCKED=PINNED_SSH_HOST_KEY_PARSE_INVALID')
fields=out[0].split()
if len(fields)<2 or fields[1] != expected:
    raise SystemExit('BLOCKED=PINNED_SSH_HOST_KEY_FINGERPRINT_MISMATCH')
if '(ED25519)' not in out[0]:
    raise SystemExit('BLOCKED=PINNED_SSH_HOST_KEY_NOT_ED25519')
print('PINNED_SSH_HOST_KEY=ONE_ED25519_RECORD_VERIFIED')
PY

CURRENT_PRIMARY="$(openclaw config get agents.defaults.model.primary 2>/dev/null | normalize_config_string || true)"
if [[ -z "$CURRENT_PRIMARY" ]]; then
  echo "BLOCKED=CURRENT_PRIMARY_MODEL_EMPTY"
  exit 103
fi

RECORD_STATE="missing"
PREVIOUS_PRIMARY=""
if [[ -s "$PROMOTION_RECORD" ]]; then
  RECORD_RESULT="$(python3 - "$PROMOTION_RECORD" "$TARGET_PRIMARY" <<'PY'
import json,sys
path,target=sys.argv[1:]
try: data=json.load(open(path,encoding='utf-8'))
except Exception: print('invalid\t'); raise SystemExit
previous=data.get('previous_primary')
recorded_target=data.get('target_primary')
if not isinstance(previous,str) or not previous.strip() or previous==target or recorded_target!=target:
    print('invalid\t')
else:
    print('valid\t'+previous)
PY
)"
  RECORD_STATE="${RECORD_RESULT%%$'\t'*}"
  PREVIOUS_PRIMARY="${RECORD_RESULT#*$'\t'}"
  if [[ "$RECORD_STATE" != "valid" ]]; then
    echo "BLOCKED=PROMOTION_ROLLBACK_RECORD_INVALID"
    exit 104
  fi
fi

if [[ "$CURRENT_PRIMARY" == "$TARGET_PRIMARY" && "$RECORD_STATE" != "valid" ]]; then
  echo "BLOCKED=TARGET_ALREADY_PRIMARY_WITHOUT_VALID_ROLLBACK_RECORD"
  exit 105
fi

set +e
RUN_LLM_TEST="$RUN_LLM_TEST" ENABLE_AFTER_VERIFY="$ENABLE_AFTER_VERIFY" SET_PRIMARY=0 bash "$CORE"
CORE_STATUS=$?
set -e
if [[ $CORE_STATUS -ne 0 ]]; then
  echo "BLOCKED=CORE_PHONE_BRIDGE_VERIFICATION_FAILED"
  exit "$CORE_STATUS"
fi
[[ -s "$RECEIPT" ]] || { echo "BLOCKED=CORE_VERIFICATION_RECEIPT_MISSING"; exit 106; }

RECEIPT_GATE="$(python3 - "$RECEIPT" <<'PY'
import json,sys
try: data=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception: print('fail'); raise SystemExit
ok=(
    data.get('direct_llm_test')=='pass' and
    data.get('cli_backend_test')=='pass' and
    data.get('backend_provider')=='phone-codex-cli' and
    data.get('gateway_health')=='pass' and
    data.get('telegram_single_poller')=='not_tested'
)
print('pass' if ok else 'fail')
PY
)"
if [[ "$RECEIPT_GATE" != "pass" ]]; then
  echo "BLOCKED=CORE_RECEIPT_GATE_FAILED"
  exit 107
fi

PROMOTED_AT=""
if [[ "$SET_PRIMARY" == "1" ]]; then
  if [[ "$RECORD_STATE" != "valid" ]]; then
    if [[ "$CURRENT_PRIMARY" == "$TARGET_PRIMARY" || -z "$CURRENT_PRIMARY" ]]; then
      echo "BLOCKED=SAFE_ROLLBACK_TARGET_REQUIRED"
      exit 108
    fi
    PROMOTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$PROMOTION_RECORD" "$CURRENT_PRIMARY" "$TARGET_PRIMARY" "$PROMOTED_AT" <<'PY'
import json,os,sys,tempfile
path,previous,target,at=sys.argv[1:]
directory=os.path.dirname(path)
os.makedirs(directory,exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix='.previous-primary.',dir=directory,text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as handle:
        json.dump({'previous_primary':previous,'target_primary':target,'recorded_at':at},handle,ensure_ascii=False,indent=2)
        handle.flush(); os.fsync(handle.fileno())
    os.chmod(tmp,0o600)
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
    PREVIOUS_PRIMARY="$CURRENT_PRIMARY"
    RECORD_STATE="valid"
  fi

  openclaw config set agents.defaults.model.primary "$TARGET_PRIMARY"
  VERIFIED_PRIMARY="$(openclaw config get agents.defaults.model.primary 2>/dev/null | normalize_config_string || true)"
  if [[ "$VERIFIED_PRIMARY" != "$TARGET_PRIMARY" ]]; then
    echo "BLOCKED=PRIMARY_MODEL_PROMOTION_NOT_VERIFIED"
    exit 109
  fi
  restart_gateway
  openclaw gateway status

  python3 - "$RECEIPT" "$PREVIOUS_PRIMARY" "$TARGET_PRIMARY" "$PROMOTED_AT" <<'PY'
import json,os,sys,tempfile
path,previous,target,promoted_at=sys.argv[1:]
data=json.load(open(path,encoding='utf-8'))
data.update({
    'result':'partial_t4_required',
    't3_bridge':'pass',
    'previous_primary':previous,
    'primary_model':target,
    'promoted_at':promoted_at or data.get('promoted_at') or None,
    'rollback_record_valid':True,
    't4_telegram_round_trip':'not_tested',
    'telegram_single_poller':'not_tested',
})
directory=os.path.dirname(path)
fd,tmp=tempfile.mkstemp(prefix='.verify-receipt.',dir=directory,text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as handle:
        json.dump(data,handle,ensure_ascii=False,indent=2)
        handle.flush(); os.fsync(handle.fileno())
    os.chmod(tmp,0o600)
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
fi

echo "RESULT=PARTIAL_T4_REQUIRED"
echo "T3_BRIDGE=PASS"
echo "PRIMARY_MODEL=$([[ "$SET_PRIMARY" == "1" ]] && echo "$TARGET_PRIMARY" || echo unchanged)"
echo "ROLLBACK_RECORD=VALID"
echo "T4_TELEGRAM=NOT_TESTED"
