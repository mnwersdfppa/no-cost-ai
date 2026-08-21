#!/usr/bin/env bash
set -Eeuo pipefail

MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"
MODEL_REF="ollama/${MODEL}"
AGENT_ID="${OPENCLAW_AGENT_ID:-telegram-frontdoor}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
CONFIG_FILE="${OPENCLAW_CONFIG_FILE:-$OPENCLAW_ROOT/openclaw.json}"
SESSION_ENV="${PI_WORK_QUEUE_ENV:-$OPENCLAW_ROOT/secrets/pi-work-queue.env}"
RECEIPT_DIR="${OPENCLAW_RUNTIME_DIR:-$OPENCLAW_ROOT/runtime}"
RECEIPT="$RECEIPT_DIR/telegram-model-recovery-receipt.json"
BACKUP=""

log() { printf '%s\n' "$*"; }
fail() { log "RESULT=BLOCKED"; log "BLOCKER=$1"; exit "${2:-1}"; }

for command in openclaw ollama python3 curl; do
  command -v "$command" >/dev/null 2>&1 || fail "MISSING_COMMAND:$command" 20
done

mkdir -p "$RECEIPT_DIR"
chmod 700 "$RECEIPT_DIR" 2>/dev/null || true

if [[ -f "$CONFIG_FILE" ]]; then
  BACKUP="${CONFIG_FILE}.before-telegram-model-recovery.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$CONFIG_FILE" "$BACKUP"
  chmod 600 "$BACKUP" 2>/dev/null || true
fi

rollback() {
  local rc=$?
  if (( rc != 0 )); then
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
      cp -p "$BACKUP" "$CONFIG_FILE"
      openclaw gateway restart >/dev/null 2>&1 || true
    fi
    python3 - "$RECEIPT" "$MODEL_REF" "$AGENT_ID" "$rc" <<'PY'
import json, pathlib, sys
path, model, agent, rc = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "result": "rolled_back",
    "model": model,
    "agent": agent,
    "exit_code": int(rc),
    "secret_values_included": False,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  fi
}
trap rollback EXIT

# Recover the existing Supabase Pi session when a refresh token is available.
# No token value is printed or written outside the existing 0600 session file.
if [[ -f "$SESSION_ENV" ]]; then
  set +u
  set -a
  # shellcheck disable=SC1090
  source "$SESSION_ENV"
  set +a
  set -u
  if [[ -n "${PI_REFRESH_TOKEN:-}" && "${SUPABASE_URL:-}" == https://* ]]; then
    refresh_payload="$(python3 - "$PI_REFRESH_TOKEN" <<'PY'
import json, sys
print(json.dumps({"refresh_token": sys.argv[1]}, separators=(",", ":")))
PY
)"
    refresh_response="$(curl -fsS --max-time 15 \
      -H 'content-type: application/json' \
      --data-binary "$refresh_payload" \
      "${SUPABASE_URL%/}/functions/v1/pi-auth-refresh" 2>/dev/null || true)"
    if [[ -n "$refresh_response" ]]; then
      python3 - "$SESSION_ENV" "$refresh_response" <<'PY'
import json, os, pathlib, sys, tempfile
path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(sys.argv[2])
except Exception:
    raise SystemExit(0)
if data.get("ok") is not True:
    raise SystemExit(0)
access = data.get("access_token")
refresh = data.get("refresh_token")
if not isinstance(access, str) or len(access) < 20:
    raise SystemExit(0)
values = {}
for raw in path.read_text(encoding="utf-8").splitlines():
    if not raw or raw.lstrip().startswith("#") or "=" not in raw:
        continue
    key, value = raw.split("=", 1)
    values[key] = value
values["PI_ACCESS_TOKEN"] = access
if isinstance(refresh, str) and len(refresh) >= 20:
    values["PI_REFRESH_TOKEN"] = refresh
content = "\n".join(f"{key}={values[key]}" for key in sorted(values)) + "\n"
fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
PY
    fi
  fi
fi

ollama_healthy() {
  curl -fsS --max-time 4 "$OLLAMA_URL/api/version" >/dev/null 2>&1
}

if ! ollama_healthy; then
  systemctl --user start ollama.service >/dev/null 2>&1 || \
    systemctl start ollama.service >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    sleep 2
    ollama_healthy && break
  done
fi
ollama_healthy || fail "OLLAMA_LOOPBACK_UNREACHABLE" 30

if ! ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$MODEL"; then
  if [[ "${OLLAMA_PULL_IF_MISSING:-1}" != "1" ]]; then
    fail "OLLAMA_MODEL_MISSING:$MODEL" 31
  fi
  ollama pull "$MODEL"
fi

# Manual model registration avoids relying on provider auto-discovery state.
openclaw config set models.providers.ollama.baseUrl '"http://127.0.0.1:11434"' --strict-json
openclaw config set models.providers.ollama.apiKey '"ollama-local"' --strict-json
openclaw config set models.providers.ollama.api '"ollama"' --strict-json
openclaw config set models.providers.ollama.timeoutSeconds '300' --strict-json
openclaw config set models.providers.ollama.models \
  "[{\"id\":\"$MODEL\",\"name\":\"$MODEL\",\"input\":[\"text\"],\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0},\"contextWindow\":32768,\"maxTokens\":4096,\"params\":{\"keep_alive\":\"15m\"}}]" \
  --strict-json --merge
openclaw config set agents.defaults.models \
  "{\"$MODEL_REF\":{\"alias\":\"Pi Local\"}}" \
  --strict-json --merge

merge_allow_path() {
  local path="$1"
  local existing merged
  existing="$(openclaw config get "$path" --json 2>/dev/null || true)"
  [[ -n "$existing" ]] || return 0
  merged="$(python3 - "$existing" "$MODEL_REF" <<'PY'
import json, sys
try:
    value = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if not isinstance(value, list):
    raise SystemExit(1)
model = sys.argv[2]
if value and model not in value and "ollama/*" not in value:
    value.append(model)
print(json.dumps(value, separators=(",", ":")))
PY
)" || return 0
  openclaw config set "$path" "$merged" --strict-json
}

merge_allow_path agents.defaults.modelPolicy.allow
merge_allow_path "agents.entries.${AGENT_ID}.modelPolicy.allow"

# Preserve the primary while replacing the ineffective same-model fallback.
agent_model="$(openclaw config get "agents.entries.${AGENT_ID}.model" --json 2>/dev/null || true)"
if [[ -n "$agent_model" && "$agent_model" != "null" ]]; then
  replacement="$(python3 - "$agent_model" "$MODEL_REF" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
fallback = sys.argv[2]
if isinstance(value, str):
    result = {"primary": value, "fallbacks": [fallback]}
elif isinstance(value, dict):
    result = dict(value)
    primary = result.get("primary")
    if not isinstance(primary, str) or not primary:
        raise SystemExit(1)
    result["fallbacks"] = [fallback]
else:
    raise SystemExit(1)
print(json.dumps(result, separators=(",", ":")))
PY
)" || fail "AGENT_MODEL_CONFIG_UNSUPPORTED" 40
  openclaw config set "agents.entries.${AGENT_ID}.model" "$replacement" --strict-json
else
  default_model="$(openclaw config get agents.defaults.model --json 2>/dev/null || true)"
  replacement="$(python3 - "$default_model" "$MODEL_REF" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
fallback = sys.argv[2]
if isinstance(value, str):
    result = {"primary": value, "fallbacks": [fallback]}
elif isinstance(value, dict):
    result = dict(value)
    primary = result.get("primary")
    if not isinstance(primary, str) or not primary:
        raise SystemExit(1)
    result["fallbacks"] = [fallback]
else:
    raise SystemExit(1)
print(json.dumps(result, separators=(",", ":")))
PY
)" || fail "DEFAULT_MODEL_CONFIG_UNSUPPORTED" 41
  openclaw config set agents.defaults.model "$replacement" --strict-json
fi

openclaw config validate
OLLAMA_API_KEY=ollama-local openclaw infer model run \
  --local \
  --model "$MODEL_REF" \
  --prompt 'Reply with exactly: pong' \
  --json >/dev/null

openclaw gateway restart
sleep 3
openclaw gateway status >/dev/null
openclaw models list --provider ollama | grep -Fq "$MODEL"

python3 - "$RECEIPT" "$MODEL_REF" "$AGENT_ID" <<'PY'
import datetime, json, pathlib, sys
path, model, agent = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "result": "verified",
    "model": model,
    "agent": agent,
    "ollama_endpoint": "http://127.0.0.1:11434",
    "provider_api": "ollama",
    "fallback_installed": True,
    "primary_preserved": True,
    "paid_fallback_enabled": False,
    "second_telegram_poller_created": False,
    "secret_values_included": False,
    "verified_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

trap - EXIT
log "RESULT=VERIFIED"
log "MODEL=$MODEL_REF"
log "AGENT=$AGENT_ID"
log "NEXT_TELEGRAM_COMMAND=/new $MODEL_REF"
log "RECEIPT=$RECEIPT"
