# OpenClaw Pi compatibility image

This image is a **diagnostic and recovery compatibility layer**, not a second OpenClaw instance.

It performs outbound-only checks against:

- Supabase `openclaw-recovery-readiness`
- Supabase `pi-work-queue` status
- Supabase Guardian model inventory
- host Ollama `/api/tags`

It writes a redacted JSON receipt to `/data/openclaw-compat-receipt.json`.

## Safety boundaries

The image:

- runs as non-root UID/GID `10001`
- requires no privileged mode, host network, Docker socket or host PID namespace
- never calls Telegram `getUpdates`
- does not create a second Telegram poller
- receives no OpenCode, OpenRouter or Tailscale provider key
- does not enable paid fallback
- does not execute queue payload commands
- does not restart OpenClaw or unknown host processes

The host keeps Tailscale and the existing OpenClaw Telegram poller.

## Architectures

The publishing workflow builds one OCI index for:

- `linux/arm64` — Raspberry Pi 5
- `linux/amd64` — desktop/server verification

Use the immutable digest emitted by the workflow rather than relying on `:edge` for long-term operation.

## Environment

Create `openclaw-pi-compat.env` with mode `0600`:

```dotenv
SUPABASE_URL=https://dpllasnpfskyyyzebyal.supabase.co
PI_ACCESS_TOKEN=<scoped pi-gateway-client access token>
SUPABASE_PUBLISHABLE_KEY=<optional public project key>
OLLAMA_URL=http://host.docker.internal:11434
```

Do not put a Supabase server key or model-provider key in this file.

## One-shot diagnostic

```bash
docker run --rm \
  --read-only \
  --user 10001:10001 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --add-host host.docker.internal:host-gateway \
  --env-file ./openclaw-pi-compat.env \
  -v openclaw-pi-compat-data:/data \
  ghcr.io/mnwersdfppa/openclaw-pi-compat:edge
```

The command returns success when either authenticated Supabase readiness or local Ollama is reachable.

## Periodic probe

```bash
docker compose -f compose.example.yml up -d
```

This mode checks every 120 seconds. It remains outbound-only and does not consume Telegram updates.

## Receipt

```bash
docker run --rm \
  -v openclaw-pi-compat-data:/data \
  --entrypoint cat \
  ghcr.io/mnwersdfppa/openclaw-pi-compat:edge \
  /data/openclaw-compat-receipt.json
```

The receipt contains status codes, latency, safe model IDs and queue counts. It contains no access token or provider credential.

## When to use it

Use this container when native OpenClaw is unreachable or when the Pi must prove that Supabase Guardian, its scoped JWT, the durable queue and Ollama are independently reachable.

Do not run it as a replacement Telegram bot or a second OpenClaw gateway.
