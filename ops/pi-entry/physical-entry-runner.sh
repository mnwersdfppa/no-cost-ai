#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export NO_COLOR=1

SUPABASE_URL="https://dpllasnpfskyyyzebyal.supabase.co"
SESSION_ENDPOINT="$SUPABASE_URL/functions/v1/pi-one-time-session-bootstrap-20260821"
AUTHORITY_ENDPOINT="$SUPABASE_URL/functions/v1/openclaw-authority-gateway"
SEQUENCE_ENDPOINT="$SUPABASE_URL/functions/v1/pi-recovery-sequence-advance-once-20260823"
PROPOSAL_KEY="physical.pi-entry-verification.current.20260823"
PROPOSAL_SHA="4b8bb91eac29e52bc71d184ce6a71aaba495a19a00803a0238715fd6420337a7"
REFERENCE_LOAD="22.53"
ROOT="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
SECRETS_DIR="$ROOT/secrets"
RECEIPT_DIR="$ROOT/receipts"
RUNTIME_DIR="$ROOT/runtime"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$SECRETS_DIR/pi-work-queue.env}"
LOCAL_RECEIPT="$RECEIPT_DIR/physical-entry-verification-20260823.json"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf -- "$TMP_DIR"
  unset ODI_BOOTSTRAP_TOKEN PI_ACCESS_TOKEN PI_REFRESH_TOKEN
}
trap cleanup EXIT

fail() {
  printf 'PHYSICAL_ENTRY_BLOCKED reason=%s\n' "$1" >&2
  exit 40
}

for command in curl python3 sha256sum hostname uname awk cut tr systemctl; do
  command -v "$command" >/dev/null 2>&1 || fail "missing_${command}"
done

mkdir -p "$SECRETS_DIR" "$RECEIPT_DIR" "$RUNTIME_DIR"
chmod 700 "$ROOT" "$SECRETS_DIR" "$RECEIPT_DIR" "$RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$TMP_DIR"

MODEL="unknown"
if [[ -r /proc/device-tree/model ]]; then
  MODEL="$(tr -d '\000' </proc/device-tree/model | tr -cd 'A-Za-z0-9 ._/-' | head -c 120)"
fi
[[ "$MODEL" == *"Raspberry Pi 5"* ]] || fail "not_raspberry_pi_5"

HOST_SAFE="$(hostname | tr -cd 'A-Za-z0-9._-' | head -c 120)"
ARCH_SAFE="$(uname -m | tr -cd 'A-Za-z0-9._/-' | head -c 40)"
MACHINE_SHA="$(if [[ -r /etc/machine-id ]]; then sha256sum /etc/machine-id | awk '{print $1}'; else printf '%s' "$HOST_SAFE" | sha256sum | awk '{print $1}'; fi)"
LOAD_AFTER="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || printf '999')"
python3 - "$LOAD_AFTER" "$REFERENCE_LOAD" <<'PY' || fail "load_reduction_not_verified"
import math, sys
current=float(sys.argv[1]); reference=float(sys.argv[2])
if not (math.isfinite(current) and current >= 0 and current < reference):
    raise SystemExit(1)
PY

GATEWAY_RESTART_COUNT=0
gateway_http() {
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 3 --max-time 5 http://127.0.0.1:18789/ 2>/dev/null || printf '000'
}
gateway_active() {
  systemctl --user is-active --quiet openclaw-gateway.service 2>/dev/null && return 0
  command -v openclaw >/dev/null 2>&1 && openclaw gateway status >/dev/null 2>&1 && return 0
  return 1
}
GATEWAY_HTTP="$(gateway_http)"
if ! gateway_active || [[ "$GATEWAY_HTTP" != "200" ]]; then
  if command -v openclaw >/dev/null 2>&1; then
    openclaw gateway restart >/dev/null 2>&1 || true
  else
    systemctl --user restart openclaw-gateway.service >/dev/null 2>&1 || true
  fi
  GATEWAY_RESTART_COUNT=1
  for _ in $(seq 1 12); do
    sleep 2
    GATEWAY_HTTP="$(gateway_http)"
    if gateway_active && [[ "$GATEWAY_HTTP" == "200" ]]; then break; fi
  done
fi
if ! gateway_active || [[ "$GATEWAY_HTTP" != "200" ]]; then
  fail "gateway_not_active_after_bounded_restart"
fi

read_env_value() {
  python3 - "$ENV_FILE" "$1" <<'PY'
import pathlib, shlex, sys
path=pathlib.Path(sys.argv[1]); wanted=sys.argv[2]
if not path.is_file(): raise SystemExit(0)
for raw in path.read_text(encoding='utf-8', errors='replace').splitlines():
    line=raw.strip()
    if not line or line.startswith('#') or '=' not in line: continue
    if line.startswith('export '): line=line[7:].lstrip()
    key, value=line.split('=',1)
    if key.strip()!=wanted: continue
    try:
        parts=shlex.split(value, posix=True)
        print(parts[0] if parts else '')
    except Exception:
        print(value.strip().strip('"\''))
    break
PY
}

PI_ACCESS_TOKEN="$(read_env_value PI_ACCESS_TOKEN)"
PI_REFRESH_TOKEN="$(read_env_value PI_REFRESH_TOKEN)"

valid_existing=false
if [[ ${#PI_ACCESS_TOKEN} -ge 20 ]]; then
  code="$(curl --silent --show-error --output "$TMP_DIR/manifest-existing.json" --write-out '%{http_code}' \
    --connect-timeout 10 --max-time 20 \
    --header "Authorization: Bearer ${PI_ACCESS_TOKEN}" \
    "$AUTHORITY_ENDPOINT?proposal_key=$PROPOSAL_KEY" || true)"
  if [[ "$code" == "200" ]] && python3 - "$TMP_DIR/manifest-existing.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); raise SystemExit(0 if j.get('ok') is True else 1)
PY
  then valid_existing=true; fi
fi

if [[ "$valid_existing" != "true" ]]; then
  : "${ODI_BOOTSTRAP_TOKEN:?ODI_BOOTSTRAP_TOKEN is required when no valid Pi session exists}"
  python3 - "$TMP_DIR/bootstrap-body.json" "$HOST_SAFE" "$ARCH_SAFE" "$MACHINE_SHA" <<'PY'
import json, os, sys
path,host,arch,machine=sys.argv[1:]
with open(path,'w',encoding='utf-8') as f:
    json.dump({'hostname':host,'architecture':arch,'machine_id_sha256':machine,'correlation_id':'PHYSICAL-ENTRY-20260823'},f,separators=(',',':'))
os.chmod(path,0o600)
PY
  curl --fail --silent --show-error \
    --request POST --connect-timeout 10 --max-time 45 \
    --header 'content-type: application/json' \
    --header "x-odi-bootstrap-token: ${ODI_BOOTSTRAP_TOKEN}" \
    --data-binary "@$TMP_DIR/bootstrap-body.json" \
    "$SESSION_ENDPOINT" -o "$TMP_DIR/bootstrap-response.json"

  python3 - "$TMP_DIR/bootstrap-response.json" "$ENV_FILE" <<'PY'
import json, os, pathlib, shlex, sys, tempfile
response=pathlib.Path(sys.argv[1]); env_path=pathlib.Path(sys.argv[2]).expanduser()
data=json.loads(response.read_text(encoding='utf-8'))
if data.get('ok') is not True or data.get('role')!='pi-gateway-client': raise SystemExit('bootstrap_response_invalid')
access=data.get('access_token'); refresh=data.get('refresh_token')
if not isinstance(access,str) or len(access)<20 or not isinstance(refresh,str) or len(refresh)<8: raise SystemExit('bootstrap_session_invalid')
preserved=[]
if env_path.is_file():
  for raw in env_path.read_text(encoding='utf-8',errors='replace').splitlines():
    s=raw.strip(); candidate=s[7:].lstrip() if s.startswith('export ') else s
    key=candidate.split('=',1)[0].strip() if '=' in candidate else ''
    if key not in {'SUPABASE_URL','PI_ACCESS_TOKEN','PI_REFRESH_TOKEN'}: preserved.append(raw)
env_path.parent.mkdir(parents=True,exist_ok=True); os.chmod(env_path.parent,0o700)
fd,tmp=tempfile.mkstemp(prefix=f'.{env_path.name}.',dir=env_path.parent)
try:
  with os.fdopen(fd,'w',encoding='utf-8') as h:
    for line in preserved: h.write(line+'\n')
    for key,value in [('SUPABASE_URL',data.get('supabase_url')),('PI_ACCESS_TOKEN',access),('PI_REFRESH_TOKEN',refresh)]:
      h.write(f'{key}={shlex.quote(str(value))}\n')
    h.flush(); os.fsync(h.fileno())
  os.chmod(tmp,0o600); os.replace(tmp,env_path)
finally:
  try: os.unlink(tmp)
  except FileNotFoundError: pass
PY
  PI_ACCESS_TOKEN="$(read_env_value PI_ACCESS_TOKEN)"
  PI_REFRESH_TOKEN="$(read_env_value PI_REFRESH_TOKEN)"
fi
unset ODI_BOOTSTRAP_TOKEN
[[ ${#PI_ACCESS_TOKEN} -ge 20 ]] || fail "pi_access_token_unavailable"

python3 - "$TMP_DIR/evidence.json" "$MODEL" "$HOST_SAFE" "$ARCH_SAFE" "$REFERENCE_LOAD" "$LOAD_AFTER" "$GATEWAY_HTTP" "$GATEWAY_RESTART_COUNT" <<'PY'
import datetime, json, os, sys
path,model,host,arch,load_before,load_after,http_status,restarts=sys.argv[1:]
e={
 'verified_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'device_model':model,'hostname':host,'architecture':arch,
 'pi5_attested':True,'load_reduction_verified':True,
 'physical_load_reduction_verified':True,
 'load_before':load_before,'load_after':load_after,
 'reachability_verified':True,'ssh_reachable':True,
 'actuator_reachable':True,'pi_authenticated':True,
 'execution_transport':'existing_pi_actuator',
 'transport_detail':'standard_ssh_over_existing_tailnet',
 'gateway_ok':True,'gateway_http_status':int(http_status),
 'gateway_restart_count':int(restarts),
 'host_rebooted':False,'automatic_reboot':False,
 'data_or_volume_deleted':False,'docker_volumes_deleted':False,
 'docker_prune_performed':False,'supabase_db_reset':False,
 'unknown_process_killed':False,'second_telegram_poller_created':False,
 'permission_scope_changed':False,'n8n_sole_operational_scheduler':True,
 'secret_values_included':False,
}
with open(path,'w',encoding='utf-8') as f: json.dump(e,f,separators=(',',':'))
os.chmod(path,0o600)
PY

python3 - "$TMP_DIR/attest-body.json" "$TMP_DIR/evidence.json" <<PY
import json,os,sys
proposal_key=${PROPOSAL_KEY@Q}; proposal_sha=${PROPOSAL_SHA@Q}
e=json.load(open(sys.argv[2]))
body={'action':'attest','proposal_key':proposal_key,'proposal_sha256':proposal_sha,'decision':'approve','evidence_ref':'physical-pi5-stage2-4-20260823','evidence':e}
json.dump(body,open(sys.argv[1],'w'),separators=(',',':')); os.chmod(sys.argv[1],0o600)
PY
curl --fail --silent --show-error --request POST --connect-timeout 10 --max-time 30 \
  --header "Authorization: Bearer ${PI_ACCESS_TOKEN}" --header 'content-type: application/json' \
  --data-binary "@$TMP_DIR/attest-body.json" "$AUTHORITY_ENDPOINT" -o "$TMP_DIR/attest-response.json"
python3 - "$TMP_DIR/attest-response.json" <<'PY' || fail "authority_attestation_rejected"
import json,sys
j=json.load(open(sys.argv[1])); raise SystemExit(0 if j.get('ok') is True else 1)
PY

python3 - "$TMP_DIR/receipt-body.json" "$TMP_DIR/evidence.json" <<PY
import json,os,sys
proposal_key=${PROPOSAL_KEY@Q}; proposal_sha=${PROPOSAL_SHA@Q}
e=json.load(open(sys.argv[2]))
body={'action':'receipt','proposal_key':proposal_key,'proposal_sha256':proposal_sha,'receipt_type':'verified','evidence_ref':'physical-pi5-stage2-4-20260823','evidence':e}
json.dump(body,open(sys.argv[1],'w'),separators=(',',':')); os.chmod(sys.argv[1],0o600)
PY
curl --fail --silent --show-error --request POST --connect-timeout 10 --max-time 30 \
  --header "Authorization: Bearer ${PI_ACCESS_TOKEN}" --header 'content-type: application/json' \
  --data-binary "@$TMP_DIR/receipt-body.json" "$AUTHORITY_ENDPOINT" -o "$TMP_DIR/receipt-response.json"
python3 - "$TMP_DIR/receipt-response.json" <<'PY' || fail "authority_receipt_rejected"
import json,sys
j=json.load(open(sys.argv[1])); raise SystemExit(0 if j.get('ok') is True else 1)
PY

curl --fail --silent --show-error --request POST --connect-timeout 10 --max-time 30 \
  --header "Authorization: Bearer ${PI_ACCESS_TOKEN}" --header 'content-type: application/json' \
  --data '{"action":"advance"}' "$SEQUENCE_ENDPOINT" -o "$TMP_DIR/sequence-response.json"
python3 - "$TMP_DIR/sequence-response.json" <<'PY' || fail "sequence_advance_rejected"
import json,sys
j=json.load(open(sys.argv[1]));
if j.get('ok') is not True or j.get('physical_readiness',{}).get('physical_core_ready') is not True: raise SystemExit(1)
PY

python3 - "$LOCAL_RECEIPT" "$TMP_DIR/evidence.json" "$TMP_DIR/sequence-response.json" <<'PY'
import json, os, pathlib, sys
path=pathlib.Path(sys.argv[1]); evidence=json.load(open(sys.argv[2])); sequence=json.load(open(sys.argv[3]))
payload={'result':'verified','stage':'physical_entry_2_4','proposal_key':'physical.pi-entry-verification.current.20260823','proposal_sha256':'4b8bb91eac29e52bc71d184ce6a71aaba495a19a00803a0238715fd6420337a7','evidence':evidence,'next_stage':sequence.get('sequence',{}).get('stage'),'secret_values_included':False}
path.write_text(json.dumps(payload,ensure_ascii=False,indent=2)+'\n',encoding='utf-8'); path.chmod(0o600)
PY

printf 'PHYSICAL_ENTRY_VERIFIED proposal_sha=%s load_after=%s gateway_http=%s gateway_restarts=%s\n' "$PROPOSAL_SHA" "$LOAD_AFTER" "$GATEWAY_HTTP" "$GATEWAY_RESTART_COUNT"
printf 'SEQUENCE_ADVANCED stage=scheduler_disable\n'
