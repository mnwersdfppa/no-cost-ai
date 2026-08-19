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
SESSION_STORE="$OPENCLAW_ROOT/agents/$AGENT_ID/sessions/sessions.json"
RECEIPT="$RUNTIME_DIR/opencode-first-tailscale-second-receipt.json"
SUPABASE_URL_DEFAULT="https://dpllasnpfskyyyzebyal.supabase.co"
PRIMARY="opencode/nemotron-3-ultra-free"
FALLBACKS='["opencode/deepseek-v4-flash-free","opencode/mimo-v2.5-free","opencode/big-pickle","opencode/laguna-s-2.1-free"]'
UTILITY="opencode/mimo-v2.5-free"
CONFIG_BACKUP=""
SESSION_BACKUP=""
TMPDIR_LOCAL=""
MODEL_VERIFIED=false
TAILSCALE_STATUS="pending"
TAILSCALE_SERVE=false

log() { printf '%s\n' "$*"; }
warn() { log "WARNING=$1"; }
fail() { log "RESULT=BLOCKED"; log "BLOCKER=$1"; exit "${2:-1}"; }

for command in openclaw curl python3; do
  command -v "$command" >/dev/null 2>&1 || fail "MISSING_COMMAND:$command" 20
done

mkdir -p "$OPENCLAW_ROOT/secrets" "$RUNTIME_DIR"
chmod 700 "$OPENCLAW_ROOT" "$OPENCLAW_ROOT/secrets" "$RUNTIME_DIR" 2>/dev/null || true
TMPDIR_LOCAL="$(mktemp -d "$RUNTIME_DIR/.opencode-first.XXXXXX")"
chmod 700 "$TMPDIR_LOCAL"

rollback_model_state() {
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
pathlib.Path(sys.argv[1]).write_text(json.dumps({
  "result":"model_recovery_rolled_back",
  "exit_code":int(sys.argv[2]),
  "secret_values_included":False,
  "recorded_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
},indent=2,sort_keys=True)+"\n",encoding="utf-8")
PY
  fi
}
trap rollback_model_state EXIT

[[ -f "$SESSION_ENV" ]] || fail "PI_SESSION_ENV_MISSING:$SESSION_ENV" 21
chmod 600 "$SESSION_ENV"
set -a
# shellcheck disable=SC1090
source "$SESSION_ENV"
set +a
SUPABASE_URL="${SUPABASE_URL:-$SUPABASE_URL_DEFAULT}"
[[ "$SUPABASE_URL" == https://* ]] || fail "HTTPS_SUPABASE_URL_REQUIRED" 22

refresh_pi_session() {
  [[ ${#PI_REFRESH_TOKEN:-0} -ge 20 ]] || return 1
  local request="$TMPDIR_LOCAL/refresh-request.json"
  local response="$TMPDIR_LOCAL/refresh-response.json"
  PI_REFRESH_TOKEN="$PI_REFRESH_TOKEN" python3 - "$request" <<'PY'
import json, os, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(
  json.dumps({"refresh_token":os.environ["PI_REFRESH_TOKEN"]},separators=(",",":")),
  encoding="utf-8",
)
PY
  curl -fsS --max-time 20 \
    -H 'content-type: application/json' \
    --data-binary "@$request" \
    "$SUPABASE_URL/functions/v1/pi-auth-refresh" > "$response" || return 1

  python3 - "$SESSION_ENV" "$response" <<'PY'
import json, os, pathlib, sys, tempfile
path=pathlib.Path(sys.argv[1]); data=json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
if data.get("ok") is not True: raise SystemExit(1)
access=data.get("access_token"); refresh=data.get("refresh_token")
if not isinstance(access,str) or len(access)<20: raise SystemExit(1)
values={}
for raw in path.read_text(encoding="utf-8").splitlines():
    if not raw or raw.lstrip().startswith("#") or "=" not in raw: continue
    key,value=raw.split("=",1); values[key]=value
values["PI_ACCESS_TOKEN"]=access
if isinstance(refresh,str) and len(refresh)>=20: values["PI_REFRESH_TOKEN"]=refresh
content="\n".join(f"{key}={values[key]}" for key in sorted(values))+"\n"
fd,tmp=tempfile.mkstemp(prefix=f".{path.name}.",dir=path.parent)
try:
    with os.fdopen(fd,"w",encoding="utf-8") as handle:
        handle.write(content); handle.flush(); os.fsync(handle.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,path)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
PY
}

# Prefer refreshing immediately, but permit an existing current access token.
refresh_pi_session >/dev/null 2>&1 || true
set -a
# shellcheck disable=SC1090
source "$SESSION_ENV"
set +a
[[ ${#PI_ACCESS_TOKEN:-0} -ge 20 ]] || fail "PI_ACCESS_OR_REFRESH_TOKEN_REQUIRED" 23

fetch_bootstrap() {
  local request="$TMPDIR_LOCAL/bootstrap-request.json"
  local response="$TMPDIR_LOCAL/bootstrap-response.json"
  python3 - "$request" <<'PY'
import json, pathlib, sys, time, uuid
pathlib.Path(sys.argv[1]).write_text(json.dumps({
  "action":"bootstrap",
  "execution_key":f"pi-infra-bootstrap-v2-{int(time.time())}",
  "correlation_id":str(uuid.uuid4()),
},separators=(",",":")),encoding="utf-8")
PY
  curl -fsS --max-time 25 \
    -H "Authorization: Bearer $PI_ACCESS_TOKEN" \
    -H 'content-type: application/json' \
    --data-binary "@$request" \
    "$SUPABASE_URL/functions/v1/pi-infra-bootstrap" > "$response"
}

if ! fetch_bootstrap; then
  refresh_pi_session || fail "PI_AUTH_REFRESH_REJECTED" 24
  set -a
  # shellcheck disable=SC1090
  source "$SESSION_ENV"
  set +a
  fetch_bootstrap || fail "PI_INFRA_BOOTSTRAP_REJECTED" 25
fi

BOOTSTRAP_RESPONSE="$TMPDIR_LOCAL/bootstrap-response.json"
SECRETS_TEMP="$TMPDIR_LOCAL/bootstrap-secrets.env"
python3 - "$PROVIDER_ENV" "$SECRETS_TEMP" "$BOOTSTRAP_RESPONSE" <<'PY'
import json, os, pathlib, shlex, sys, tempfile
provider_path=pathlib.Path(sys.argv[1]); temp_path=pathlib.Path(sys.argv[2])
data=json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
if data.get("ok") is not True or data.get("destination")!="authenticated_pi_only":
    raise SystemExit("BOOTSTRAP_CONTRACT_REJECTED")
provider=data.get("provider") or {}; tailscale=data.get("tailscale") or {}
opencode=provider.get("OPENCODE_API_KEY"); authkey=tailscale.get("TAILSCALE_AUTHKEY")
if not isinstance(opencode,str) or len(opencode)<20: raise SystemExit("OPENCODE_KEY_MISSING")
if not isinstance(authkey,str) or len(authkey)<20: raise SystemExit("TAILSCALE_AUTHKEY_MISSING")
provider_path.parent.mkdir(parents=True,exist_ok=True); os.chmod(provider_path.parent,0o700)
content=f"OPENCODE_API_KEY={shlex.quote(opencode)}\n"
fd,tmp=tempfile.mkstemp(prefix=f".{provider_path.name}.",dir=provider_path.parent)
try:
    with os.fdopen(fd,"w",encoding="utf-8") as handle:
        handle.write(content); handle.flush(); os.fsync(handle.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,provider_path)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
temp_path.write_text(
  f"OPENCODE_API_KEY={shlex.quote(opencode)}\nTAILSCALE_AUTHKEY={shlex.quote(authkey)}\n",
  encoding="utf-8",
)
os.chmod(temp_path,0o600)
PY
chmod 600 "$PROVIDER_ENV" "$SECRETS_TEMP"
set -a
# shellcheck disable=SC1090
source "$SECRETS_TEMP"
set +a
export OPENCODE_API_KEY

# Back up before changing the effective OpenClaw model configuration.
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_BACKUP="$CONFIG_FILE.before-opencode-v2.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$CONFIG_FILE" "$CONFIG_BACKUP"
  chmod 600 "$CONFIG_BACKUP" 2>/dev/null || true
fi

# Persist only the OpenCode key. The Tailscale enrollment key remains temporary.
UNIT="$(systemctl --user list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /openclaw.*gateway.*\.service|openclaw-gateway\.service/ {print $1; exit}')"
if [[ -n "$UNIT" ]]; then
  DROPIN="$HOME/.config/systemd/user/$UNIT.d"
  mkdir -p "$DROPIN"
  chmod 700 "$HOME/.config" "$HOME/.config/systemd" "$HOME/.config/systemd/user" "$DROPIN" 2>/dev/null || true
  printf '[Service]\nEnvironmentFile=%s\n' "$PROVIDER_ENV" > "$DROPIN/20-opencode-provider.conf"
  chmod 600 "$DROPIN/20-opencode-provider.conf"
  systemctl --user daemon-reload
else
  OPEN_CODE_JSON="$(OPENCODE_API_KEY="$OPENCODE_API_KEY" python3 -c 'import json,os; print(json.dumps(os.environ["OPENCODE_API_KEY"]))')"
  openclaw config set env.vars.OPENCODE_API_KEY "$OPEN_CODE_JSON" --strict-json
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
fi

MODEL_OBJECT="$(PRIMARY="$PRIMARY" FALLBACKS="$FALLBACKS" python3 - <<'PY'
import json, os
print(json.dumps({
  "primary":os.environ["PRIMARY"],
  "fallbacks":json.loads(os.environ["FALLBACKS"]),
},separators=(",",":")))
PY
)"
MODELS_CATALOG='{"opencode/*":{"alias":"OpenCode Zen"},"opencode/nemotron-3-ultra-free":{"alias":"Zen Nemotron Free"},"opencode/deepseek-v4-flash-free":{"alias":"Zen DeepSeek Free"},"opencode/mimo-v2.5-free":{"alias":"Zen MiMo Free"},"opencode/big-pickle":{"alias":"Zen Big Pickle"},"opencode/laguna-s-2.1-free":{"alias":"Zen Laguna Free"}}'

openclaw config set agents.defaults.models "$MODELS_CATALOG" --strict-json --merge
openclaw config set agents.defaults.model "$MODEL_OBJECT" --strict-json
openclaw config set agents.defaults.utilityModel "\"$UTILITY\"" --strict-json

merge_allow() {
  local path="$1" current merged
  current="$(openclaw config get "$path" --json 2>/dev/null || true)"
  [[ -n "$current" && "$current" != "null" ]] || return 0
  merged="$(python3 - "$current" <<'PY'
import json, sys
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
  openclaw config set "agents.entries.$AGENT_ID.utilityModel" "\"$UTILITY\"" --strict-json
  merge_allow "agents.entries.$AGENT_ID.modelPolicy.allow"
fi

openclaw config validate
openclaw models list --provider opencode > "$TMPDIR_LOCAL/opencode-models.txt"
for ref in "$PRIMARY" \
  opencode/deepseek-v4-flash-free \
  opencode/mimo-v2.5-free \
  opencode/big-pickle \
  opencode/laguna-s-2.1-free; do
  grep -Fq "${ref#opencode/}" "$TMPDIR_LOCAL/opencode-models.txt" \
    || fail "OPENCODE_MODEL_NOT_AVAILABLE:$ref" 40
done

# Clear only the known Telegram model/auth pins. Conversation content remains intact.
if [[ -f "$SESSION_STORE" ]]; then
  SESSION_BACKUP="$SESSION_STORE.before-model-unpin-v2.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$SESSION_STORE" "$SESSION_BACKUP"
  python3 - "$SESSION_STORE" "$TELEGRAM_SESSION_KEY" <<'PY'
import json, os, pathlib, sys, tempfile
path=pathlib.Path(sys.argv[1]); target=sys.argv[2]
data=json.loads(path.read_text(encoding="utf-8")); changed=False
remove={
  "providerOverride","modelOverride","modelOverrideSource","modelOverrideAt",
  "authProfileOverride","authProfileOverrideSource","providerProfileOverride",
}
def walk(value,key_hint=None):
    global changed
    if isinstance(value,dict):
        matched=(key_hint==target or value.get("sessionKey")==target or value.get("key")==target)
        if matched:
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

# A live model completion is mandatory before Telegram traffic is restarted.
if openclaw infer model run --help >/dev/null 2>&1; then
  openclaw infer model run \
    --model "$PRIMARY" \
    --prompt 'Reply with exactly: pong' \
    --json > "$TMPDIR_LOCAL/model-smoke.json"
elif openclaw agent --help 2>/dev/null | grep -q -- '--model'; then
  openclaw agent \
    --agent "$AGENT_ID" \
    --message 'Reply with exactly: pong' \
    --model "$PRIMARY" \
    --json > "$TMPDIR_LOCAL/model-smoke.json"
else
  fail "NO_SUPPORTED_MODEL_SMOKE_COMMAND" 41
fi
grep -qi 'pong' "$TMPDIR_LOCAL/model-smoke.json" || fail "OPENCODE_MODEL_SMOKE_FAILED" 42
MODEL_VERIFIED=true

openclaw gateway restart
sleep 4
openclaw gateway status >/dev/null 2>&1 || fail "OPENCLAW_GATEWAY_RECOVERY_FAILED" 43
openclaw channels status --probe >/dev/null 2>&1 || true

# Model recovery is now committed. Tailscale is independent and best-effort.
CONFIG_BACKUP=""
SESSION_BACKUP=""

try_tailscale() {
  local installer="$TMPDIR_LOCAL/tailscale-install.sh"
  local -a sudo_cmd=()
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo_cmd=(sudo -n)
  fi

  if ! command -v tailscale >/dev/null 2>&1; then
    [[ "${INSTALL_TAILSCALE_IF_MISSING:-1}" == "1" ]] || {
      TAILSCALE_STATUS="cli_missing"
      return 0
    }
    [[ ${#sudo_cmd[@]} -gt 0 || $EUID -eq 0 ]] || {
      TAILSCALE_STATUS="install_needs_privilege"
      return 0
    }
    curl -fsS --max-time 30 https://tailscale.com/install.sh -o "$installer" || {
      TAILSCALE_STATUS="installer_download_failed"
      return 0
    }
    grep -q 'tailscale' "$installer" || {
      TAILSCALE_STATUS="installer_validation_failed"
      return 0
    }
    "${sudo_cmd[@]}" sh "$installer" >/dev/null 2>&1 || {
      TAILSCALE_STATUS="install_failed"
      return 0
    }
  fi

  [[ ${#sudo_cmd[@]} -gt 0 || $EUID -eq 0 ]] || {
    TAILSCALE_STATUS="up_needs_privilege"
    return 0
  }
  "${sudo_cmd[@]}" systemctl enable --now tailscaled >/dev/null 2>&1 || true

  local backend
  backend="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print((json.load(sys.stdin).get("BackendState") or "").lower())' 2>/dev/null || true)"
  if [[ "$backend" != "running" ]]; then
    "${sudo_cmd[@]}" tailscale up \
      --auth-key="$TAILSCALE_AUTHKEY" \
      --hostname=raspberry-pi5-openclaw \
      --ssh \
      --accept-dns=true \
      --accept-routes=false >/dev/null 2>&1 || {
      TAILSCALE_STATUS="auth_key_rejected_or_expired"
      return 0
    }
  else
    "${sudo_cmd[@]}" tailscale set --ssh=true >/dev/null 2>&1 || true
  fi

  tailscale status --json > "$TMPDIR_LOCAL/tailscale-status.json" 2>/dev/null || {
    TAILSCALE_STATUS="status_failed"
    return 0
  }
  python3 - "$TMPDIR_LOCAL/tailscale-status.json" <<'PY' || {
import json, pathlib, sys
data=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if str(data.get("BackendState","")).lower()!="running": raise SystemExit(1)
if not (data.get("Self") or {}).get("TailscaleIPs"): raise SystemExit(1)
PY
    TAILSCALE_STATUS="joined_without_verified_ip"
    return 0
  }

  TAILSCALE_STATUS="joined"
  openclaw config set gateway.bind '"loopback"' --strict-json
  openclaw config set gateway.auth.allowTailscale 'true' --strict-json
  openclaw config set gateway.tailscale.mode '"serve"' --strict-json
  if openclaw config validate && openclaw gateway restart >/dev/null 2>&1; then
    sleep 3
    if openclaw gateway status >/dev/null 2>&1; then
      TAILSCALE_SERVE=true
      return 0
    fi
  fi

  # Keep Tailscale SSH even when Serve/HTTPS is unavailable.
  openclaw config set gateway.tailscale.mode '"off"' --strict-json || true
  openclaw config validate >/dev/null 2>&1 || true
  openclaw gateway restart >/dev/null 2>&1 || true
  TAILSCALE_SERVE=false
  return 0
}
try_tailscale
unset TAILSCALE_AUTHKEY
rm -f "$SECRETS_TEMP"

# Best-effort heartbeat; no secret material is included.
HEARTBEAT="$TMPDIR_LOCAL/heartbeat.json"
MODEL_VERIFIED="$MODEL_VERIFIED" TAILSCALE_STATUS="$TAILSCALE_STATUS" python3 - "$HEARTBEAT" <<'PY'
import json, os, pathlib, sys, time, uuid
pathlib.Path(sys.argv[1]).write_text(json.dumps({
  "action":"heartbeat",
  "execution_key":f"opencode-v2-heartbeat-{int(time.time()//300)}",
  "correlation_id":str(uuid.uuid4()),
  "node_name":"raspberry-pi5",
  "node_type":"raspberry_pi",
  "status":"online",
  "capabilities":{
    "gateway_healthy":True,
    "openclaw_status_healthy":True,
    "opencode_healthy":os.environ.get("MODEL_VERIFIED")=="true",
    "tailscale_running":os.environ.get("TAILSCALE_STATUS")=="joined",
    "telegram_poller_created":False,
    "paid_api_fallback_requested":False,
  },
  "metadata":{"source":"recover-opencode-first-tailscale-second","secret_values_included":False},
},separators=(",",":")),encoding="utf-8")
PY
curl -fsS --max-time 15 \
  -H "Authorization: Bearer $PI_ACCESS_TOKEN" \
  -H 'content-type: application/json' \
  --data-binary "@$HEARTBEAT" \
  "$SUPABASE_URL/functions/v1/emergency-bridge" >/dev/null 2>&1 || true

python3 - "$RECEIPT" "$PRIMARY" "$FALLBACKS" "$UTILITY" "$TAILSCALE_STATUS" "$TAILSCALE_SERVE" <<'PY'
import datetime, json, pathlib, sys
path,primary,fallbacks,utility,tailscale_status,tailscale_serve=sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
  "result":"verified" if tailscale_status=="joined" else "model_verified_tailscale_pending",
  "primary":primary,
  "fallbacks":json.loads(fallbacks),
  "utility_model":utility,
  "opencode_model_smoke":True,
  "tailscale_status":tailscale_status,
  "tailscale_serve_enabled":tailscale_serve=="true",
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
log "RESULT=MODEL_VERIFIED"
log "PRIMARY=$PRIMARY"
log "FALLBACKS=4_DISTINCT_OPENCODE_FREE_MODELS"
log "TAILSCALE_STATUS=$TAILSCALE_STATUS"
log "TAILSCALE_SERVE=$TAILSCALE_SERVE"
log "TELEGRAM_POLLER=EXISTING_SINGLE_POLLER"
log "RECEIPT=$RECEIPT"
