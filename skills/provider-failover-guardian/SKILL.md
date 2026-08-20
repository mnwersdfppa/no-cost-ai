---
name: provider-failover-guardian
description: Hide transient provider failures from Telegram by using a bounded model circuit breaker, distinct fallback routes and durable request preservation.
version: 1
status: verified
---

# Provider Failover Guardian

## Canonical route

- Gateway: `pi-model-gateway-guardian`
- API: OpenAI Responses compatible
- Primary: `supabase-opencode/nemotron-3-ultra-free`
- Distinct cloud fallback: `supabase-opencode/laguna-s-2.1-free`
- Independent fallback after physical verification: `ollama/qwen2.5:3b`

The OpenCode provider credential remains in Supabase Edge. It is never returned to Raspberry Pi, Telegram, Docker, GitHub, Notion, or evidence.

## Fixed flow

1. Validate the requested model against the canonical route.
2. Skip models whose quarantine has not expired.
3. Attempt at most two distinct immediate cloud models.
4. Record success or a bounded failure result in model health.
5. On total failure, enqueue the original secret-free request with an idempotency key.
6. Return a Telegram-safe acknowledgement rather than the upstream overload or unavailable-model text.
7. Retry through the server worker and deliver through the existing OpenClaw outbound path.

## Circuit breaker

- HTTP 429: long quarantine
- HTTP 5xx: short quarantine
- timeout: short quarantine
- successful output: clear quarantine

## Safety boundaries

- one existing Telegram inbound poller only
- no raw upstream error text to Telegram
- no provider secret export
- no paid automatic fallback
- no arbitrary process termination
- no automatic merge or Production deployment
- no command, script, executable, or Authorization field in queued evidence

## Verification

Prove unauthorized rejection, primary output, fallback selection, forced total-failure queue acknowledgement, duplicate suppression, test cleanup, and `secret_values_included=false`.
