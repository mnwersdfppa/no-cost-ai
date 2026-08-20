---
name: pattern-promotion-engine
description: Mine repeated OpenClaw operational errors, decisions and reasoning friction, score them, and promote low-risk deterministic patterns into verified macros and skills.
version: 1
status: candidate
---

# Pattern Promotion Engine

## Use this skill when

- The same error, recovery step, status check, approval or explanation appears repeatedly.
- A known API, MCP tool, connector, macro, host adapter or container may replace fresh model reasoning.
- An operational pattern needs evidence, a score, CI, E2E and rollback before activation.
- Supabase should be the machine-authoritative record and Notion should receive a human projection.

## Do not use this skill when

- The request is a one-off creative task with no repeatable operational structure.
- The proposed automation requires unauthorized access, credential theft, stealth persistence, policy evasion or destructive action.
- The pattern is high-risk or critical and lacks explicit, scope-bound approval.
- A verified native API or existing deterministic skill already resolves the intent; call that capability directly instead.

## Authority and routing

1. Supabase is the authoritative store for patterns, observations, feedback, scores, skill versions and capability routes.
2. GitHub Draft PRs are the code, migration, CI and rollback evidence.
3. Notion is a human-readable projection and historical evidence store. It must not overwrite authoritative runtime state.
4. Resolve known intents in this order:
   - native API
   - MCP
   - connected app or connector
   - deterministic macro
   - host adapter
   - hardened container
   - local model
   - cloud model
   - manual review

## Workflow

### 1. Observe

Collect safe metadata from:

- `bridge_events`
- `openclaw_work_queue`
- `bridge_request_ledger`
- `command_decisions`
- approved Notion evidence links
- scoped Pi/OpenClaw feedback through `openclaw-pattern-engine`

Normalize and hash observations before storage. Exact duplicates reuse the same observation. Similar but non-identical records remain separate review candidates.

Never store raw credentials, authorization headers, private keys, access tokens, refresh tokens or provider error payloads.

### 2. Score

The deterministic SQL scorer combines:

- 30-day and 90-day frequency
- failures and duplicate events
- estimated time and token savings
- evidence volume
- deterministic execution bonus
- reversible execution bonus
- risk penalty
- posterior success from observed outcomes and feedback

The scorer does not require an LLM.

### 3. Select a stage

- `observe`: insufficient evidence
- `macro_candidate`: repeated and suitable for a bounded deterministic macro
- `skill_candidate`: strong enough to create source, tests and a rollback contract
- `verified`: CI and E2E passed
- `active`: low risk, score at least 85, CI pass, E2E pass, rollback spec, verification spec and named skill
- `quarantined`: unsafe or repeatedly failing
- `retired`: superseded or no longer relevant

High-risk and critical patterns cannot be automatically promoted to verified or active.

### 4. Reuse before invention

Before creating implementation, inspect in this order:

1. existing named OpenClaw skill
2. native product API or CLI
3. MCP tool or connected app
4. existing repository artifact or workflow
5. official open-source component
6. small deterministic adapter
7. new model-generated implementation

Use optional components only when their operational need is proven:

- LangGraph: long-running, interruptible state graphs requiring checkpoints
- n8n: external API fan-out and visual operations; queue mode only when distributed workers are justified
- OpenTelemetry Collector: standardized traces, metrics and logs with batching and retries
- OPA: separate policy decisions from execution for multiple enforcement points
- Docker/OCI: portable, unprivileged workloads across `linux/arm64` and `linux/amd64`

Keep systemd, Tailscale daemon control, Ollama acceleration, OpenClaw Gateway control and the Telegram inbound poller in the host adapter.

## API contract

Endpoint:

```text
https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/openclaw-pattern-engine
```

Authentication:

```text
Authorization: Bearer <scoped pi-gateway-client JWT>
```

Exposed actions:

- `status`
- `candidates`
- `resolve`
- `observe`
- `feedback`

The API deliberately does not expose a promotion action or arbitrary execution primitive.

### Resolve example

```json
{
  "action": "resolve",
  "intent_key": "status.read",
  "context": {
    "node": "raspberry-pi5"
  }
}
```

### Observation example

```json
{
  "action": "observe",
  "execution_key": "gateway-status-20260820T120000Z",
  "pattern_key": "gateway-port-restart-guard",
  "category": "error",
  "severity": "warning",
  "outcome": "known_unit_unhealthy",
  "success": false,
  "duration_ms": 250,
  "tokens_saved_estimate": 400,
  "minutes_saved_estimate": 5,
  "safe_context": {
    "port": 18789,
    "unknown_process_killed": false
  }
}
```

### Feedback example

```json
{
  "action": "feedback",
  "execution_key": "gateway-recovery-20260820T120100Z",
  "pattern_key": "gateway-port-restart-guard",
  "outcome": "succeeded",
  "reward": 0.8,
  "skill_name": "gateway-liveness-guard",
  "skill_version": 1,
  "latency_ms": 3200,
  "manual_intervention": false,
  "safe_evidence": {
    "gateway_healthy": true,
    "restart_count": 1
  }
}
```

## Promotion guard

Activation must be performed through the internal Supabase RPC and must fail unless all of the following hold:

- risk level is low
- promotion score is at least 85
- CI state is pass
- E2E state is pass
- rollback specification exists
- verification specification exists
- skill name exists

Promotion must remain unavailable from the Pi-facing API.

## Mandatory safety properties

- No arbitrary queue-payload command execution.
- No `eval`, `exec`, shell interpolation or downloaded `curl | sh` execution.
- No second Telegram inbound poller.
- No provider key, service-role key or raw secret in Pi, Docker images, GitHub files, Notion or evidence.
- No Docker socket, privileged container or host network by default.
- No automatic paid model fallback.
- No automatic PR merge or Production deployment.
- No automatic deletion of historical Notion pages.
- No unknown-process termination.

## Rollback

1. Disable the pattern candidate or capability route.
2. Stop the named cron job or named worker only.
3. Restore the previous canonical route or skill version.
4. Preserve observations, feedback and receipts.
5. Never delete shared credentials as part of rollback.
6. Record a rollback receipt with no secret values.

## Verified cloud evidence

- Unauthorized API request: HTTP 401
- Authenticated status: HTTP 200
- API-first capability resolution: HTTP 200
- Safe observation: HTTP 200
- Duplicate execution key: HTTP 409
- Secret-like payload: HTTP 400
- Executable payload field: HTTP 400
- Safe feedback: HTTP 200
- Temporary identity and rows removed
- Provider and server secrets not returned

## Physical Pi completion

The cloud skill is not physical-Pi complete until the existing Pi JWT calls `status` and `resolve`, the host adapter reports its local capabilities, and a secret-free receipt is attached to the Supabase completion gate.
