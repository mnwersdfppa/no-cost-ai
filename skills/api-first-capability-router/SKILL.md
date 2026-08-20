---
name: api-first-capability-router
description: Route OpenClaw intents to one verified structured capability before spending model tokens or creating overlapping infrastructure.
version: 1
status: candidate
---

# API-First Capability Router

## Goal

Resolve known operational intents without fresh model reasoning whenever an existing API, MCP tool, connector, deterministic macro, host adapter, or validated container can satisfy the contract.

## Route order

1. Verified native API
2. MCP capability
3. Connected app or connector
4. Deterministic SQL or macro
5. Fixed host adapter
6. Hardened compatibility container
7. Local model
8. Cloud model
9. Manual review

A verified native API is preferred when available.

## One-owner rule

Each intent has one authoritative owner:

- Supabase: SSOT, durable queue, pattern score, short scheduler
- OpenClaw Gateway: runtime status, model routing, message send
- Existing OpenClaw Telegram integration: sole inbound poller
- systemd host adapter: named services and timers
- Docker: portable unprivileged validation
- n8n candidate: external API fan-out
- LangGraph candidate: long-running interruptible state graph
- OpenTelemetry candidate: telemetry normalization
- Notion: human-readable projection

Do not activate a second owner until there is a migration, rollback, and deduplication contract.

## Resolve contract

Call the existing Pattern Engine with:

```json
{
  "action": "resolve",
  "intent_key": "status.read",
  "context": {
    "node": "raspberry-pi5"
  }
}
```

Return the selected capability and its endpoint, cost tier, permission risk, reliability, network requirement, and metadata.

## Routing rules

- Status, readiness, credential presence, queue state, and deterministic calculations must not call an LLM.
- Use MCP only where a native API is absent or incomplete.
- Use n8n for connector work, not as authoritative state.
- Use LangGraph only when checkpoint, interrupt, and resume semantics are required.
- Use Docker only for portable workloads. Host devices, systemd, Tailscale, Ollama acceleration, Gateway control, and Telegram inbound polling remain native.
- Unknown intents fail closed to manual review. Unknown intents route to manual review.

## Safety boundaries

- Never return credentials, provider keys, Supabase server keys, refresh tokens, Authorization headers, or credential values.
- No arbitrary command or executable path from a queue payload.
- No automatic permission elevation, credential creation, paid fallback, merge, or Production deployment.
- No second Telegram poller.
- No unknown-process termination.
- No provider secret in Pi, Docker, GitHub, Notion, or evidence.

## Output

`intent_key`, `selected_capability`, `capability_type`, `provider`, `operation`, `endpoint_ref`, `deterministic`, `cost_tier`, `permission_risk`, `reliability_score`, `manual_review_required`, `secret_values_included=false`.
