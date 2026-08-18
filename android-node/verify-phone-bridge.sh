#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
RUN_LLM_TEST="${RUN_LLM_TEST:-1}"
ENABLE_AFTER_VERIFY="${ENABLE_AFTER_VERIFY:-1}"
SET_PRIMARY="${SET_PRIMARY:-1}"
TARGET_PRIMARY="phone-codex-cli/gpt-5.6-sol"
PROMOTION_RECORD="$ROOT/previous-primary.json"

restart_gateway() {
  if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
    openclaw gateway restart --safe
  else
    openclaw gateway restart
  fi
}

normalize_config_string() {
  python3 -c '
import json,sys
raw=sys.stdin.read().strip()
try:
    value=json.loads(raw)
except Exception:
    value=raw
if isinstance(value,str):
    print(value)
'
}

fingerprint_file() {
  ssh-keygen -lf "$1" -E sha256 2>/dev/null | awk 'NR==1 {print $2}'
}

if [[ "$ENABLE_AFTER_VERIFY" == "1" && "$RUN_LLM_TEST" != "1" ]]; then
  echo "BLOCKED=LIVE_LLM_TEST_REQUIRED_BEFORE_ENABLE"
  exit 29
fi
if [[ ! -r "$ENV_FILE" ]]; then
  echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING"
  exit 30
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "${PHONE_SSH_HOST_KEY_SHA256:-}" || "$PHONE_SSH_HOST_KEY_SHA256" != SHA256:* ]]; then
  echo "BLOCKED=OPERATOR_VERIFIED_SSH_FINGERPRINT_REQUIRED"
  echo "NEXT=run the phone bootstrap, compare its PHONE_SSH_HOST_KEY_SHA256 on the phone screen, then record that exact value in $ENV_FILE"
  exit 31
fi

adb start-server >/dev/null
if [[ "$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)" != "device" ]]; then
  echo "BLOCKED=ADB_DEVICE_NOT_READY"
  exit 32
fi
adb -s "$ANDROID_SERIAL" forward --remove tcp:"$PHONE_SSH_PORT" >/dev/null 2>&1 || true
adb -s "$ANDROID_SERIAL" forward tcp:"$PHONE_SSH_PORT" tcp:8022 >/dev/null

if [[ -z "${PHONE_SSH_USER:-}" ]]; then
  echo "BLOCKED=TERMUX_USER_UNKNOWN"
  echo "NEXT=run id -un in Termux and set PHONE_SSH_USER in $ENV_FILE"
  exit 33
fi

TMP_KNOWN="$(mktemp)"
trap 'rm -f "$TMP_KNOWN"' EXIT
if ! ssh-keyscan -T 10 -t ed25519 -p "$PHONE_SSH_PORT" "$PHONE_SSH_HOST" > "$TMP_KNOWN" 2>/dev/null; then
  echo "BLOCKED=PHONE_SSHD_NOT_REACHABLE"
  echo "NEXT=run bash /sdcard/Download/openclaw-phone-bootstrap.sh in Termux"
  exit 34
fi
if [[ ! -s "$TMP_KNOWN" ]]; then
  echo "BLOCKED=PHONE_SSH_HOST_KEY_EMPTY"
  exit 35
fi
SCANNED_FP="$(fingerprint_file "$TMP_KNOWN")"
if [[ "$SCANNED_FP" != "$PHONE_SSH_HOST_KEY_SHA256" ]]; then
  echo "BLOCKED=PHONE_SSH_FINGERPRINT_MISMATCH"
  echo "EXPECTED=$PHONE_SSH_HOST_KEY_SHA256"
  echo "SCANNED=$SCANNED_FP"
  exit 36
fi
if [[ -s "$PHONE_SSH_KNOWN_HOSTS" ]]; then
  EXISTING_FP="$(fingerprint_file "$PHONE_SSH_KNOWN_HOSTS")"
  if [[ "$EXISTING_FP" != "$PHONE_SSH_HOST_KEY_SHA256" ]]; then
    echo "BLOCKED=PINNED_SSH_HOST_KEY_CHANGED"
    echo "EXPECTED=$PHONE_SSH_HOST_KEY_SHA256"
    echo "PINNED=$EXISTING_FP"
    exit 37
  fi
else
  install -m 600 "$TMP_KNOWN" "$PHONE_SSH_KNOWN_HOSTS"
fi

SSH=(
  ssh
  -p "$PHONE_SSH_PORT"
  -i "$PHONE_SSH_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$PHONE_SSH_KNOWN_HOSTS"
  -o ConnectTimeout=10
  "$PHONE_SSH_USER@$PHONE_SSH_HOST"
)

REMOTE_STATUS="$("${SSH[@]}" phone-status 2>&1 || true)"
printf '%s\n' "$REMOTE_STATUS"
if ! grep -q 'runner=ready' <<<"$REMOTE_STATUS"; then
  echo "BLOCKED=PHONE_RUNNER_NOT_READY"
  exit 38
fi
REMOTE_FP="$(sed -n 's/^host_key_fingerprint=//p' <<<"$REMOTE_STATUS" | tail -n1)"
if [[ "$REMOTE_FP" != "$PHONE_SSH_HOST_KEY_SHA256" ]]; then
  echo "BLOCKED=REMOTE_STATUS_FINGERPRINT_MISMATCH"
  exit 39
fi
if ! grep -q "CODEX_VERSION=${PHONE_CODEX_VERSION:-0.146.0}\|codex-cli ${PHONE_CODEX_VERSION:-0.146.0}\|codex ${PHONE_CODEX_VERSION:-0.146.0}" <<<"$REMOTE_STATUS"; then
  echo "BLOCKED=PHONE_CODEX_VERSION_NOT_ALLOWLISTED"
  exit 40
fi

DENY_TEST="$("${SSH[@]}" uname -a 2>&1 || true)"
if ! grep -q 'DENIED=COMMAND_NOT_ALLOWLISTED' <<<"$DENY_TEST"; then
  echo "BLOCKED=FORCED_COMMAND_POLICY_NOT_ACTIVE"
  exit 41
fi
if ! grep -Eqi 'Logged in using ChatGPT|chatgpt|authenticated|login.*ok|successfully logged in' <<<"$REMOTE_STATUS"; then
  echo "BLOCKED=PHONE_CODEX_NOT_LOGGED_IN"
  echo "NEXT=run codex login --device-auth in Termux and approve it in the phone browser"
  exit 42
fi

parse_phone_final() {
  python3 -c '
import json,sys
raw=sys.stdin.read()
final=""
fatal=""
plain=[]
for source in raw.splitlines():
    line=source.strip()
    if not line:
        continue
    try:
        event=json.loads(line)
    except Exception:
        plain.append(line)
        continue
    typ=str(event.get("type", ""))
    if typ in {"error", "turn.failed"}:
        fatal=event.get("message") or (event.get("error") or {}).get("message") or line
    item=event.get("item")
    if not isinstance(item,dict) and isinstance(event.get("data"),dict):
        item=event["data"].get("item")
    if isinstance(item,dict) and item.get("type")=="agent_message" and isinstance(item.get("text"),str):
        final=item["text"]
    if typ=="turn.completed" and isinstance(event.get("final_output"),str):
        final=event["final_output"]
if fatal:
    raise SystemExit(70)
if not final and plain:
    final=plain[-1]
sys.stdout.write(final.strip())
'
}

LLM_RESULT="not_run"
if [[ "$RUN_LLM_TEST" == "1" ]]; then
  REQUEST='{"version":1,"model":"gpt-5.6-sol","prompt":"Reply exactly PHONE_CODEX_OK and nothing else."}'
  LLM_OUTPUT="$(printf '%s\n' "$REQUEST" | "${SSH[@]}" phone-codex-run 2>&1 || true)"
  LLM_FINAL="$(printf '%s' "$LLM_OUTPUT" | parse_phone_final 2>/dev/null || true)"
  if [[ "$LLM_FINAL" == "PHONE_CODEX_OK" ]]; then
    LLM_RESULT="pass"
  else
    printf '%s\n' "$LLM_OUTPUT" | tail -n 40
    echo "BLOCKED=PHONE_CODEX_LIVE_TEST_FAILED"
    exit 43
  fi
fi

if [[ "$ENABLE_AFTER_VERIFY" == "1" ]]; then
  sed -i 's/^PHONE_CODEX_ENABLED=.*/PHONE_CODEX_ENABLED=1/' "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  export PHONE_CODEX_ENABLED=1
fi

openclaw mcp doctor android-phone-status --probe
openclaw mcp doctor android-phone-inspect --probe
openclaw mcp doctor phone-codex --probe
openclaw mcp status --verbose
openclaw nodes status || true
openclaw gateway call node.list --params '{}' || true

PLUGIN_RESULT="not_supported"
BACKEND_TEST="not_run"
BACKEND_PROVIDER=""
BACKEND_MODEL=""
if openclaw plugins --help >/dev/null 2>&1; then
  if ! openclaw plugins inspect phone-codex-cli --runtime >/dev/null 2>&1; then
    openclaw plugins install -l "$ROOT/phone-codex-cli-backend"
  fi
  openclaw plugins enable phone-codex-cli || true
  if openclaw plugins inspect phone-codex-cli --runtime >/dev/null 2>&1; then
    PLUGIN_RESULT="ready"
    restart_gateway
    set +e
    BACKEND_OUTPUT="$(openclaw agent --agent main --message 'Reply exactly PHONE_BACKEND_OK and nothing else.' --model "$TARGET_PRIMARY" --json 2>&1)"
    BACKEND_STATUS=$?
    set -e
    BACKEND_CHECK="$(printf '%s' "$BACKEND_OUTPUT" | python3 -c '
import json,sys
raw=sys.stdin.read()
try: data=json.loads(raw)
except Exception: raise SystemExit(2)
status=data.get("status")
meta=data.get("meta") if isinstance(data.get("meta"),dict) else {}
agent=meta.get("agentMeta") if isinstance(meta.get("agentMeta"),dict) else {}
provider=data.get("provider") or agent.get("provider") or ""
model=data.get("model") or agent.get("model") or ""
texts=[]
if isinstance(data.get("final"),str): texts.append(data["final"])
for payload in data.get("payloads") or []:
    if isinstance(payload,dict) and isinstance(payload.get("text"),str): texts.append(payload["text"])
result=data.get("result") if isinstance(data.get("result"),dict) else {}
for payload in result.get("payloads") or []:
    if isinstance(payload,dict) and isinstance(payload.get("text"),str): texts.append(payload["text"])
final=(texts[-1].strip() if texts else "")
print(json.dumps({"ok":status in (None,"ok") and final=="PHONE_BACKEND_OK", "provider":provider, "model":model}))
' 2>/dev/null || true)"
    if [[ $BACKEND_STATUS -eq 0 && -n "$BACKEND_CHECK" ]]; then
      BACKEND_PROVIDER="$(printf '%s' "$BACKEND_CHECK" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("provider",""))' 2>/dev/null || true)"
      BACKEND_MODEL="$(printf '%s' "$BACKEND_CHECK" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("model",""))' 2>/dev/null || true)"
      BACKEND_OK="$(printf '%s' "$BACKEND_CHECK" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("ok") else "0")' 2>/dev/null || echo 0)"
    else
      BACKEND_OK=0
    fi
    if [[ "$BACKEND_OK" == "1" && "$BACKEND_PROVIDER" == "phone-codex-cli" ]]; then
      BACKEND_TEST="pass"
    else
      BACKEND_TEST="fail"
      printf '%s\n' "$BACKEND_OUTPUT" | tail -n 60
    fi
  else
    PLUGIN_RESULT="install_failed_mcp_fallback_ready"
  fi
fi

CURRENT_PRIMARY="$(openclaw config get agents.defaults.model.primary 2>/dev/null | normalize_config_string || true)"
PREVIOUS_PRIMARY=""
if [[ -s "$PROMOTION_RECORD" ]]; then
  PREVIOUS_PRIMARY="$(python3 - "$PROMOTION_RECORD" <<'PY'
import json,sys
try: data=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: data={}
value=data.get("previous_primary")
if isinstance(value,str): print(value)
PY
)"
fi
PRIMARY_RESULT="unchanged"
PROMOTED_AT=""
if [[ "$SET_PRIMARY" == "1" && "$BACKEND_TEST" == "pass" ]]; then
  if [[ "$CURRENT_PRIMARY" != "$TARGET_PRIMARY" && ! -s "$PROMOTION_RECORD" ]]; then
    PROMOTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$PROMOTION_RECORD" "$CURRENT_PRIMARY" "$TARGET_PRIMARY" "$PROMOTED_AT" <<'PY'
import json,os,sys
path,previous,target,at=sys.argv[1:]
with open(path,"w",encoding="utf-8") as f:
    json.dump({"previous_primary":previous,"target_primary":target,"recorded_at":at},f,ensure_ascii=False,indent=2)
os.chmod(path,0o600)
PY
    PREVIOUS_PRIMARY="$CURRENT_PRIMARY"
  fi
  openclaw config set agents.defaults.model.primary "$TARGET_PRIMARY"
  PRIMARY_RESULT="$TARGET_PRIMARY"
fi

openclaw mcp reload || true
GATEWAY_RESULT="fail"
if restart_gateway && openclaw gateway status; then
  GATEWAY_RESULT="pass"
fi

mkdir -p "$ROOT/logs"
T3_RESULT="partial"
if [[ "$LLM_RESULT" == "pass" && "$BACKEND_TEST" == "pass" && "$PRIMARY_RESULT" == "$TARGET_PRIMARY" && "$GATEWAY_RESULT" == "pass" ]]; then
  T3_RESULT="pass"
fi
cat > "$ROOT/logs/verify-receipt.json" <<JSON
{
  "result": "partial_t4_required",
  "t3_bridge": "$T3_RESULT",
  "t4_telegram_round_trip": "not_tested",
  "adb": "device",
  "ssh": "operator_verified_fingerprint",
  "ssh_fingerprint": "$PHONE_SSH_HOST_KEY_SHA256",
  "forced_command": "pass",
  "codex_login": "chatgpt",
  "codex_version": "${PHONE_CODEX_VERSION:-0.146.0}",
  "runner": "ready",
  "direct_llm_test": "$LLM_RESULT",
  "cli_plugin": "$PLUGIN_RESULT",
  "cli_backend_test": "$BACKEND_TEST",
  "backend_provider": "$BACKEND_PROVIDER",
  "backend_model": "$BACKEND_MODEL",
  "previous_primary": "$PREVIOUS_PRIMARY",
  "primary_model": "$PRIMARY_RESULT",
  "promoted_at": "$PROMOTED_AT",
  "gateway_health": "$GATEWAY_RESULT",
  "phone_codex_enabled": "$ENABLE_AFTER_VERIFY",
  "mcp_actions_enabled": false,
  "secrets_printed": false,
  "telegram_single_poller": "not_tested"
}
JSON
chmod 600 "$ROOT/logs/verify-receipt.json"

echo "RESULT=PARTIAL_T4_REQUIRED"
echo "T3_BRIDGE=$T3_RESULT"
echo "DIRECT_LLM_TEST=$LLM_RESULT"
echo "CLI_PLUGIN=$PLUGIN_RESULT"
echo "CLI_BACKEND_TEST=$BACKEND_TEST"
echo "BACKEND_PROVIDER=$BACKEND_PROVIDER"
echo "BACKEND_MODEL=$BACKEND_MODEL"
echo "PRIMARY_MODEL=$PRIMARY_RESULT"
echo "GATEWAY=$GATEWAY_RESULT"
echo "TELEGRAM_TEST=not_tested; use the existing OpenClaw bot only and record a correlation ID before claiming completion"
