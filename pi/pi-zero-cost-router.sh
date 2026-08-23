#!/usr/bin/env bash
set -euo pipefail

# Zero-cost-first AI router for Raspberry Pi/OpenClaw.
# Priority: local Ollama (no inference API fee) -> optional OpenRouter free model -> stop.
# Paid OpenAI is intentionally NOT used by this script.

INPUT="${*:-오늘 할 일을 간단히 정리해줘}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"
OPENROUTER_ENV="${OPENROUTER_ENV:-$HOME/.openclaw/secrets/openrouter.env}"

json_escape() {
  python3 - "$1" <<'PY'
import json,sys
print(json.dumps(sys.argv[1], ensure_ascii=False))
PY
}

# 1) Local Ollama: preferred, no external inference API charge.
if curl -fsS --max-time 2 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
  payload=$(python3 - "$OLLAMA_MODEL" "$INPUT" <<'PY'
import json,sys
model,text=sys.argv[1:]
print(json.dumps({
  "model": model,
  "messages": [{"role":"user","content":text}],
  "stream": False
}, ensure_ascii=False))
PY
)
  curl -fsS "$OLLAMA_URL/api/chat" \
    -H 'Content-Type: application/json' \
    -d "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("message",{}).get("content", ""))'
  exit 0
fi

# 2) Optional OpenRouter free router. Never use a paid model here.
if [[ -f "$OPENROUTER_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$OPENROUTER_ENV"
  set +a
fi

if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  payload=$(python3 - "$INPUT" <<'PY'
import json,sys
print(json.dumps({
  "model": "openrouter/free",
  "messages": [{"role":"user","content":sys.argv[1]}]
}, ensure_ascii=False))
PY
)
  curl -fsS https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H 'Content-Type: application/json' \
    -d "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("choices",[{}])[0].get("message",{}).get("content", ""))'
  exit 0
fi

echo "NO_COST_PROVIDER_UNAVAILABLE: Ollama is not reachable and OPENROUTER_API_KEY is not configured." >&2
exit 75
