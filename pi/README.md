# Raspberry Pi zero-cost AI route

Default policy:
1. Local Ollama on `127.0.0.1:11434` using `qwen2.5:3b`.
2. If local Ollama is unavailable, optionally use OpenRouter `openrouter/free` when `~/.openclaw/secrets/openrouter.env` contains `OPENROUTER_API_KEY`.
3. Never fall through to paid OpenAI automatically.

This is designed for ordinary OpenClaw tasks such as chat, summarization, classification, planning and lightweight coding. It is not coding-only.

## Pi install/use

```bash
chmod +x pi/pi-zero-cost-router.sh
./pi/pi-zero-cost-router.sh "오늘 일정 정리해줘"
```

OpenClaw/n8n/Telegram can invoke this script as the default text route. Keep provider secrets only under `~/.openclaw/secrets/*.env` with mode `0600`.

## Cost policy

- Local Ollama inference: no per-token external API fee; electricity/hardware costs still exist.
- OpenRouter `openrouter/free`: free model route, subject to free-tier rate limits and model availability.
- OpenAI API: emergency/manual route only. Do not auto-fallback to it.
