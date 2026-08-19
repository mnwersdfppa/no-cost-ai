#!/usr/bin/env bash
set -euo pipefail

ROOT="${HOME}/.openclaw"
BIN="$ROOT/bin"
mkdir -p "$BIN" "$ROOT/secrets"
chmod 700 "$ROOT" "$ROOT/secrets"

SCRIPT="$BIN/ai-zero-cost"
cat > "$SCRIPT" <<'ROUTER'
#!/usr/bin/env bash
set -euo pipefail
INPUT="${*:-안녕하세요}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"
ENV="$HOME/.openclaw/secrets/openrouter.env"

if curl -fsS --max-time 2 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
 python3 - "$OLLAMA_MODEL" "$INPUT" <<'PY' | curl -fsS "$OLLAMA_URL/api/chat" -H 'content-type: application/json' -d @- | python3 -c 'import json,sys; print(json.load(sys.stdin).get("message",{}).get("content",""))'
import json,sys
print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":sys.argv[2]}],"stream":False},ensure_ascii=False))
PY
 exit 0
fi

[[ -f "$ENV" ]] && { set -a; source "$ENV"; set +a; }
if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
 python3 - "$INPUT" <<'PY' | curl -fsS https://openrouter.ai/api/v1/chat/completions -H "Authorization: Bearer $OPENROUTER_API_KEY" -H 'content-type: application/json' -d @- | python3 -c 'import json,sys; print(json.load(sys.stdin).get("choices",[{}])[0].get("message",{}).get("content",""))'
import json,sys
print(json.dumps({"model":"openrouter/free","messages":[{"role":"user","content":sys.argv[1]}]},ensure_ascii=False))
PY
 exit 0
fi

echo 'NO_COST_PROVIDER_UNAVAILABLE' >&2
exit 75
ROUTER
chmod 700 "$SCRIPT"

echo "installed=$SCRIPT"
if curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
 echo 'ollama=reachable'
else
 echo 'ollama=unreachable'
fi
printf '%s\n' 'OpenClaw/Telegram command handler should call:' "$SCRIPT \"<message text>\""
printf '%s\n' 'Policy: local Ollama -> OpenRouter free (optional) -> STOP. Paid OpenAI never automatic.'
