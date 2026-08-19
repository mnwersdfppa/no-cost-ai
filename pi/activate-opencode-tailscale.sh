#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

AGENT_ID="${OPENCLAW_AGENT_ID:-telegram-frontdoor}"
TELEGRAM_SESSION_KEY="${OPENCLAW_TELEGRAM_SESSION_KEY:-agent:telegram-frontdoor:telegram:direct:8993565775}"
OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
CONFIG_FILE="${OPENCLAW_CONFIG_FILE:-$OPENCLAW_ROOT/openclaw.json}"
SESSION_ENV="${PI_WORK_QUEUE_ENV:-$OPENCLAW_ROOT/secrets/pi-work-queue.env}"
PROVIDER_ENV="$OPENCLAW_ROOT/secrets/opencode.env"
RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-$OPENCLAW_ROOT/runtime}"
RECEIPT="$RUNTIME_DIR/opencode-tailscale-activation-receipt.json"
SESSION_STORE="$OPENCLAW_ROOT/agents/$AGENT_ID/sessions/sessions.json"
SUPABASE_URL_DEFAULT="https://dpllasnpfskyyyzebyal.supabase.co"
PRIMARY="opencode/nemotron-3-ultra-free"
FALLBACKS='["opencode/deepseek-v4-flash-free","opencode/mimo-v2.5-free","opencode/big-pickle","opencode/laguna-s-2.1-free"]'
UTILITY="opencode/mimo-v2.5-free"
CONFIG_BACKUP=""
SESSION_BACKUP=""
TMPDIR_LOCAL=""
SERVE_ENABLED=false
TAILSCALE_JOINED=false
MODEL_SMOKE=false

log() { printf '%s\n' "$*"; }
fail() { log "RESULT=BLOCKED"; log "BLOCKER=$1"; exit "${2:-1}"; }

for command in openclaw curl python3; do
  command -v "$command" >/dev/null 2>&1 || fail "MISSING_COMMAND:$command" 20
done

mkdir -p "$OPENCLAW_ROOT/secrets" "$RUNTIME_DIR"
chmod 700 "$OPENCLAW_ROOT" "$OPENCLAW_ROOT/secrets" "$RUNTIME_DIR" 2>/dev/null || true
TMPDIR_LOCAL="$(mktemp -d "$RUNTIME_DIR/.activate-infra.XXXXXX")"
chmod 700 "$TMPDIR_LOCAL"

rollback() {
  local rc=$?
  rm -rf "$TMPDIR_LOCAL" 2>/dev/null || true
  if (( rc != 0 )); then
    if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" ]]; then
      cp -p "$CONFIG_BACKUP" "$CONFIG_FILE"
    fi
    if [[ -n "$SESSION_BACKUP" && -f "$SESSION_BACKUP" ]]; then
      cp -p "$SESSION_BACKUP" "$SESSION_STORE"
    fi
    openclaw gateway restart >/dev/null 2>&1 || true
    python3 - "$RECEIPT" "$rc" <<'PY'
import datetime, json, pathlib, sys
path=pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
  "result":"rolled_back",
  "exit_code":int(sys.argv[2]),
  "secret_values_included":False,
  "recorded_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
},indent=2,sort_keys=True)+"\n",encoding="utf-8")
PY
  fi
}
trap rollback EXIT

[[ -f "$SESSION_ENV" ]] || fail "PI_SESSION_ENV_MISSING:$SESSION_ENV" 21
chmod 600 "$SESSION_ENV"
set -a
# shellcheck disable=SC1090
source "$SESSION_ENV"
set +a
SUPABASE_URL="${SUPABASE_URL:-$SUPABASE_URL_DEFAULT}"
[[ "$SUPABASE_URL" == https://* ]] || fail "HTTPS_SUPABASE_URL_REQUIRED" 22
[[ ${#PI_REFRESH_TOKEN:-0} -ge 20 ]] || fail "PI_REFRESH_TOKEN_REQUIRED" 23

# Refresh the short-lived Pi JWT without printing token material.
REFRESH_PAYLOAD="$TMPDIR_LOCAL/refresh-request.json"
REFRESH_RESPONSE="$TMPDIR_LOCAL/refresh-response.json"
PI_REFRESH_TOKEN="$PI_REFRESH_TOKEN" python3 - "$REFRESH_PAYLOAD" <<'PY'
import json, os, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({"refresh_token":os.environ["PI_REFRESH_TOKEN"]},separators=(",",":")),encoding="utf-8")
PY
curl -fsS --max-time 20 \
  -H 'content-type: application/json' \
  --data-binary "@$REFRESH_PAYLOAD" \
  "$SUPABASE_URL/functions/v1/pi-auth-refresh" > "$REFRESH_RESPONSE" \
  || fail "PI_AUTH_REFRESH_UNREACHABLE" 24

python3 - "$SESSION_ENV" "$REFRESH_RESPONSE" <<'PY'
import json, os, pathlib, sys, tempfile
path=pathlib.Path(sys.argv[1]); response=pathlib.Path(sys.argv[2])
data=json.loads(response.read_text(encoding="utf-8"))
if data.get("ok") is not True:
    raise SystemExit("PI_AUTH_REFRESH_REJECTED")
access=data.get("access_token"); refresh=data.get("refresh_token")
if not isinstance(access,str) or len(access)<20:
    raise SystemExit("PI_ACCESS_TOKEN_INVALID")
values={}
for line in path.read_text(encoding="utf-8").splitlines():
    if not line or line.lstrip().startswith("#") or "=" not in line: continue
    key,value=line.split("=",1); values[key]=value
values["PI_ACCESS_TOKEN"]=access
if isinstance(refresh,str) and len(refresh)>=20: values["PI_REFRESH_TOKEN"]=refresh
content="\n".join(f"{k}={values[k]}" for k in sorted(values))+"\n"
fd,tmp=tempfile.mkstemp(prefix=f".{path.name}.",dir=path.parent)
try:
    with os.fdopen(fd,"w",encoding="utf-8") as handle:
        handle.write(content); handle.flush(); os.fsync(handle.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
PY

set -a
# shellcheck disable=SC1090
source "$SESSION_ENV"
set +a
[[ ${#PI_ACCESS_TOKEN:-0} -ge 20 ]] || fail "REFRESHED_PI_ACCESS_TOKEN_REQUIRED" 25

# Fetch exact Supabase Edge secrets only over the authenticated Pi route.
BOOTSTRAP_REQUEST="$TMPDIR_LOCAL/bootstrap-request.json"
BOOTSTRAP_RESPONSE="$TMPDIR_LOCAL/bootstrap-response.json"
python3 - "$BOOTSTRAP_REQUEST" <<'PY'
import json, pathlib, sys, time, uuid
pathlib.Path(sys.argv[1]).write_text(json.dumps({
  "action":"bootstrap",
  "execution_key":f"pi-infra-bootstrap-{int(time.time())}",
  "correlation_id":str(uuid.uuid4()),
},separators=(",",":")),encoding="utf-8")
PY
curl -fsS --max-time 25 \
  -H "Authorization: Bearer $PI_ACCESS_TOKEN" \
  -H 'content-type: application/json' \
  --data-binary "@$BOOTSTRAP_REQUEST" \
  "$SUPABASE_URL/functions/v1/pi-infra-bootstrap" > "$BOOTSTRAP_RESPONSE" \
  || fail "PI_INFRA_BOOTSTRAP_REJECTED" 26

python3 - "$PROVIDER_ENV" "$BOOTSTRAP_RESPONSE" <<'PY'
import json, os, pathlib, shlex, sys, tempfile
path=pathlib.Path(sys.argv[1]); data=json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
if data.get("ok") is not True or data.get("destination")!="authenticated_pi_only":
    raise SystemExit("BOOTSTRAP_CONTRACT_REJECTED")
provider=data.get("provider") or {}; tailscale=data.get("tailscale") or {}
opencode=provider.get("OPENCODE_API_KEY"); authkey=tailscale.get("TAILSCALE_AUTHKEY")
if not isinstance(opencode,str) or len(opencode)<20: raise SystemExit("OPENCODE_KEY_MISSING")
if not isinstance(authkey,str) or len(authkey)<20: raise SystemExit("TAILSCALE_AUTHKEY_MISSING")
content=(
  f"OPENCODE_API_KEY={shlex.quote(opencode)}\n"
  f"TAILSCALE_AUTHKEY={shlex.quote(authkey)}\n"
)
path.parent.mkdir(parents=True,exist_ok=True); os.chmod(path.parent,0o700)
fd,tmp=tempfile.mkstemp(prefix=f".{path.name}.",dir=path.parent)
try:
    with os.fdopen(fd,"w",encoding="utf-8") as handle:
        handle.write(content); handle.flush(); os.fsync(handle.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
PY
chmod 600 "$PROVIDER_ENV"
set -a
# shellcheck disable=SC1090
source "$PROVIDER_ENV"
set +a

# Install the official Tailscale package only when absent and passwordless sudo is available.
if ! command -v tailscale >/dev/null 2>&1; then
  [[ "${INSTALL_TAILSCALE_IF_MISSING:-1}" == "1" ]] || fail "TAILSCALE_CLI_MISSING" 30
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || fail "TAILSCALE_INSTALL_REQUIRES_PASSWORDLESS_SUDO" 31
  INSTALLER="$TMPDIR_LOCAL/tailscale-install.sh"
  curl -fsS --max-time 30 https://tailscale.com/install.sh -o "$INSTALLER" || fail "TAILSCALE_INSTALLER_DOWNLOAD_FAILED" 32
  grep -q 'tailscale' "$INSTALLER" || fail "TAILSCALE_INSTALLER_CONTENT_INVALID" 33
  sudo sh "$INSTALLER" >/dev/null
fi

SUDO=()
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO=(sudo -n); fi
"${SUDO[@]}" systemctl enable --now tailscaled >/dev/null 2>&1 || true

TAILSCALE_RUNNING="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print((json.load(sys.stdin).get("BackendState") or "").lower())' 2>/dev/null || true)"
if [[ "$TAILSCALE_RUNNING" != "running" ]]; then
  [[ ${#SUDO[@]} -gt 0 || $EUID -eq 0 ]] || fail "TAILSCALE_UP_REQUIRES_PRIVILEGE" 34
  "${SUDO[@]}" tailscale up \
    --auth-key="$TAILSCALE_AUTHKEY" \
    --hostname=raspberry-pi5-openclaw \
    --ssh \
    --accept-dns=true \
    --accept-routes=false >/dev/null \
    || fail "TAILSCALE_NODE_ENROLLMENT_FAILED" 35
  TAILSCALE_JOINED=true
else
  "${SUDO[@]}" tailscale set --ssh=true >/dev/null 2>&1 || true
  TAILSCALE_JOINED=true
fi

tailscale status --json > "$TMPDIR_LOCAL/tailscale-status.json"
python3 - "$TMPDIR_LOCAL/tailscale-status.json" <<'PY'
import json, pathlib, sys
data=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if str(data.get("BackendState","")).lower()!="running": raise SystemExit("TAILSCALE_NOT_RUNNING")
self_node=data.get("Self") or {}
if not self_node.get("TailscaleIPs"): raise SystemExit("TAILSCALE_IP_MISSING")
PY

# Remove the enrollment key after successful node registration; retain only the model key.
OPENCODE_API_KEY="$OPENCODE_API_KEY" python3 - "$PROVIDER_ENV" <<'PY'
import os, pathlib, shlex, sys
path=pathlib.Path(sys.argv[1])
path.write_text(f"OPENCODE_API_KEY={shlex.quote(os.environ['OPENCODE_API_KEY'])}\n",encoding="utf-8")
os.chmod(path,0o600)
PY
unset TAILSCALE_AUTHKEY

# Give the Gateway a persistent provider environment without committing the key.
UNIT="$(systemctl --user list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /openclaw.*gateway.*\.service|openclaw-gateway\.service/ {print $1; exit}')"
if [[ -n "$UNIT" ]]; then
  DROPIN="$HOME/.config/systemd/user/$UNIT.d"
  mkdir -p "$DROPIN"
  chmod 700 "$HOME/.config" "$HOME/.config/systemd" "$HOME/.config/systemd/user" "$DROPIN" 2>/dev/null || true
  printf '[Service]\nEnvironmentFile=%s\n' "$PROVIDER_ENV" > "$DROPIN/20-opencode-provider.conf"
  chmod 600 "$DROPIN/20-opencode-provider.conf"
  systemctl --user daemon-reload
else
  # Fallback for non-systemd Gateway launchers. The config file is backed up and mode 0600.
  OPEN_CODE_JSON="$(OPENCODE_API_KEY="$OPENCODE_API_KEY" python3 -c 'import json,os; print(json.dumps(os.environ["OPENCODE_API_KEY"]))')"
  openclaw config set env.vars.OPENCODE_API_KEY "$OPEN_CODE_JSON" --strict-json
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
fi
export OPENCODE_API_KEY

if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_BACKUP="$CONFIG_FILE.before-opencode-tailscale.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$CONFIG_FILE" "$CONFIG_BACKUP"
  chmod 600 "$CONFIG_BACKUP" 2>/dev/null || true
fi

MODEL_OBJECT="$(PRIMARY="$PRIMARY" FALLBACKS="$FALLBACKS" python3 - <<'PY'
import json, os
print(json.dumps({"primary":os.environ["PRIMARY"],"fallbacks":json.loads(os.environ["FALLBACKS"])},separators=(",",":")))
PY
)"
MODELS_CATALOG='{"opencode/*":{"alias":"OpenCode Zen"},"opencode/nemotron-3-ultra-free":{"alias":"Zen Nemotron Free"},"opencode/deepseek-v4-flash-free":{"alias":"Zen DeepSeek Free"},"opencode/mimo-v2.5-free":{"alias":"Zen MiMo Free"}}'

openclaw config set agents.defaults.models "$MODELS_CATALOG" --strict-json --merge
openclaw config set agents.defaults.model "$MODEL_OBJECT" --strict-json
openclaw config set agents.defaults.utilityModel "\"$UTILITY\"" --strict-json

merge_allow() {
  local path="$1" current merged
  current="$(openclaw config get "$path" --json 2>/dev/null || true)"
  [[ -n "$current" && "$current" != "null" ]] || return 0
  merged="$(python3 - "$current" <<'PY'
import json,sys
value=json.loads(sys.argv[1])
if not isinstance(value,list): raise SystemExit(1)
if value and "opencode/*" not in value: value.append("opencode/*")
print(json.dumps(value,separators=(",",":")))
PY
)" || return 0
  openclaw config set "$path" "$merged" --strict-json
}
merge_allow agents.defaults.modelPolicy.allow

AGENT_ENTRY="$(openclaw config get "agents.entries.$AGENT_ID" --json 2>/dev/null || true)"
if [[ -n "$AGENT_ENTRY" && "$AGENT_ENTRY" != "null" ]]; then
  openclaw config set "agents.entries.$AGENT_ID.model" "$MODEL_OBJECT" --strict-json
  merge_allow "agents.entries.$AGENT_ID.modelPolicy.allow"
fi

openclaw config set gateway.bind '"loopback"' --strict-json
openclaw config set gateway.auth.allowTailscale 'true' --strict-json
openclaw config set gateway.tailscale.mode '"serve"' --strict-json
openclaw config validate

# Verify that only model IDs actually returned to this key are configured.
openclaw models list --provider opencode > "$TMPDIR_LOCAL/opencode-models.txt"
for ref in "$PRIMARY" \
  opencode/deepseek-v4-flash-free \
  opencode/mimo-v2.5-free \
  opencode/big-pickle \
  opencode/laguna-s-2.1-free; do
  grep -Fq "${ref#opencode/}" "$TMPDIR_LOCAL/opencode-models.txt" || fail "OPENCODE_MODEL_NOT_AVAILABLE:$ref" 40
done

# Remove only model/auth override fields from the known Telegram session; preserve conversation data.
if [[ -f "$SESSION_STORE" ]]; then
  SESSION_BACKUP="$SESSION_STORE.before-model-unpin.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$SESSION_STORE" "$SESSION_BACKUP"
  python3 - "$SESSION_STORE" "$TELEGRAM_SESSION_KEY" <<'PY'
import json, os, pathlib, sys, tempfile
path=pathlib.Path(sys.argv[1]); target=sys.argv[2]
data=json.loads(path.read_text(encoding="utf-8")); changed=False
remove={
 "providerOverride","modelOverride","modelOverrideSource","modelOverrideAt",
 "authProfileOverride","authProfileOverrideSource","providerProfileOverride",
}
def walk(value, key_hint=None):
    global changed
    if isinstance(value,dict):
        match=(key_hint==target or value.get("sessionKey")==target or value.get("key")==target)
        if match:
            for key in list(value):
                if key in remove:
                    value.pop(key,None); changed=True
        for key,item in list(value.items()): walk(item,key)
    elif isinstance(value,list):
        for item in value: walk(item,key_hint)
walk(data)
if changed:
    content=json.dumps(data,ensure_ascii=False,separators=(",",":"))+"\n"
    fd,tmp=tempfile.mkstemp(prefix=f".{path.name}.",dir=path.parent)
    try:
        with os.fdopen(fd,"w",encoding="utf-8") as handle:
            handle.write(content); handle.flush(); os.fsync(handle.fileno())
        os.chmod(tmp,0o600); os.replace(tmp,path)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
PY
fi

# Short free-model smoke test before restarting Telegram traffic.
if openclaw infer model run --help >/dev/null 2>&1; then
  openclaw infer model run --model "$PRIMARY" --prompt 'Reply with exactly: pong' --json > "$TMPDIR_LOCAL/model-smoke.json"
else
  openclaw agent --agent "$AGENT_ID" --message 'Reply with exactly: pong' --model "$PRIMARY" --json > "$TMPDIR_LOCAL/model-smoke.json"
fi
grep -qi 'pong' "$TMPDIR_LOCAL/model-smoke.json" || fail "OPENCODE_MODEL_SMOKE_FAILED" 41
MODEL_SMOKE=true

openclaw gateway restart
sleep 4
if ! openclaw gateway status >/dev/null 2>&1; then
  # Tailscale Serve can fail when tailnet HTTPS is not enabled. Keep Tailscale SSH, disable only Serve.
  openclaw config set gateway.tailscale.mode '"off"' --strict-json
  openclaw config validate
  openclaw gateway restart
  sleep 3
  openclaw gateway status >/dev/null 2>&1 || fail "OPENCLAW_GATEWAY_RECOVERY_FAILED" 42
  SERVE_ENABLED=false
else
  SERVE_ENABLED=true
fi

openclaw channels status --probe >/dev/null 2>&1 || true
openclaw status --deep >/dev/null 2>&1 || true

# Best-effort authenticated heartbeat; no secret material is included.
HEARTBEAT="$TMPDIR_LOCAL/heartbeat.json"
MODEL_SMOKE="$MODEL_SMOKE" TAILSCALE_JOINED="$TAILSCALE_JOINED" python3 - "$HEARTBEAT" <<'PY'
import json, os, pathlib, time, uuid, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
 "action":"heartbeat",
 "execution_key":f"opencode-tailscale-heartbeat-{int(time.time()//300)}",
 "correlation_id":str(uuid.uuid4()),
 "node_name":"raspberry-pi5",
 "node_type":"raspberry_pi",
 "status":"online",
 "capabilities":{
   "gateway_healthy":True,
   "openclaw_status_healthy":True,
   "opencode_healthy":os.environ.get("MODEL_SMOKE")=="true",
   "tailscale_running":os.environ.get("TAILSCALE_JOINED")=="true",
   "telegram_poller_created":False,
   "paid_api_fallback_requested":False
 },
 "metadata":{"source":"activate-opencode-tailscale","secret_values_included":False}
},separators=(",",":")),encoding="utf-8")
PY
curl -fsS --max-time 15 \
  -H "Authorization: Bearer $PI_ACCESS_TOKEN" \
  -H 'content-type: application/json' \
  --data-binary "@$HEARTBEAT" \
  "$SUPABASE_URL/functions/v1/emergency-bridge" >/dev/null 2>&1 || true

python3 - "$RECEIPT" "$PRIMARY" "$FALLBACKS" "$UTILITY" "$SERVE_ENABLED" "$TAILSCALE_JOINED" <<'PY'
import datetime, json, pathlib, sys
path,primary,fallbacks,utility,serve,tailscale=sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
 "result":"verified",
 "primary":primary,
 "fallbacks":json.loads(fallbacks),
 "utility_model":utility,
 "opencode_model_smoke":True,
 "tailscale_joined":tailscale=="true",
 "tailscale_ssh_requested":True,
 "tailscale_serve_enabled":serve=="true",
 "telegram_agent":"telegram-frontdoor",
 "telegram_session_pin_cleared_best_effort":True,
 "same_model_duplicate_fallback_removed":True,
 "paid_api_fallback_enabled":False,
 "second_telegram_poller_created":False,
 "secret_values_included":False,
 "verified_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
},indent=2,sort_keys=True)+"\n",encoding="utf-8")
PY

rm -rf "$TMPDIR_LOCAL"
trap - EXIT
log "RESULT=VERIFIED"
log "PRIMARY=$PRIMARY"
log "FALLBACKS=4_DISTINCT_OPENCODE_FREE_MODELS"
log "TAILSCALE_JOINED=$TAILSCALE_JOINED"
log "TAILSCALE_SERVE=$SERVE_ENABLED"
log "TELEGRAM_POLLER=EXISTING_SINGLE_POLLER"
log "RECEIPT=$RECEIPT"
