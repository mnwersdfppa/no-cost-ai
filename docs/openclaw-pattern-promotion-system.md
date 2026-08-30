# OpenClaw Pattern Promotion System

## Purpose

The Pattern Promotion System converts repeated OpenClaw operational friction into bounded automation:

```text
observation -> score -> macro candidate -> skill candidate -> verified -> active
```

It is designed to remove repeated model reasoning from known status checks, credential checks, queue operations, runtime compatibility decisions and recovery routines.

## Authority model

- **Supabase**: machine-authoritative patterns, observations, feedback, scores, skill versions, capability routes and completion gates.
- **GitHub Draft PR**: migrations, Edge Function source, CI, manifests and rollback evidence.
- **Notion**: human-readable projection and historical evidence. It is never allowed to overwrite Supabase runtime state.
- **Raspberry Pi / OpenClaw**: execution host for verified host adapters and local services.
- **Telegram**: command and notification projection. A delivered message is not by itself proof of full completion.

## Live cloud state

- Supabase project: `dpllasnpfskyyyzebyal`
- Edge Function: `openclaw-pattern-engine` v1
- Function digest: `c700f0db0e01f84216ad7c5428760d765afb4578bb17878572eadf6bb761b3f6`
- Harvester: every 15 minutes
- Score refresh: hourly at minute 7
- Enabled pattern rules: 19
- Pattern candidates: 13
- Capability routes: 25
- Notion evidence links: 14

## Current leading patterns

| Pattern | 30-day frequency | Score | State |
|---|---:|---:|---|
| Provider overload and unavailable-model failover | 58 | 80.00 | verified |
| Durable queue and bounded retry | 25 | 80.00 | verified |
| Pi authentication and device identity recovery | 8 | 76.97 | skill candidate |
| State fingerprint deduplication | 7 | 72.87 | skill candidate |
| Runtime compatibility resolver | 9 | 70.03 | verified |

Counts are operational snapshots, not permanent constants. Supabase refreshes them from current evidence.

## API-first capability resolution

The resolver selects the lowest-risk, lowest-cost and most deterministic verified capability in this order:

1. native API
2. MCP
3. connected app or connector
4. deterministic macro
5. host adapter
6. hardened container
7. local model
8. cloud model
9. manual review

Examples:

| Intent | Preferred capability |
|---|---|
| `status.read` | Supabase recovery readiness API |
| `credential.check` | Supabase credential readiness API |
| `work.enqueue` | Supabase durable work queue |
| `work.schedule` | Supabase Cron |
| `runtime.compatibility` | Docker multi-architecture resolver |
| `memory.canonical_write` | Supabase Command Center |
| `memory.project_human` | Notion connector projection |
| `model.generate` | Supabase Guardian; local Ollama only after Pi verification |

Unknown intents fail closed and require review.

## Portable versus host-bound execution

### Docker / OCI

Use a hardened multi-architecture container for portable validation and artifact work across:

- `linux/arm64`
- `linux/amd64`

Default container policy:

- read-only root filesystem
- non-root user
- `--cap-drop=ALL`
- no Docker socket
- no host PID namespace
- no host network
- read-only workspace mount
- bounded memory, CPU and PID limits

### Host adapter

Keep these outside containers:

- systemd user services
- OpenClaw Gateway ownership and bounded restart
- Tailscale daemon and node enrollment
- Ollama hardware acceleration
- existing Telegram inbound poller

The host adapter may operate only named services and must never kill an unknown process.

## Open-source reuse policy

Optional components are registered but disabled until a concrete need and E2E evidence exist:

- **LangGraph**: durable checkpoints for long-running interruptible state graphs.
- **n8n**: external API fan-out and visual operations. Queue mode is justified only for distributed workers.
- **OpenTelemetry Collector**: standardized traces, metrics and logs with batching, filtering and retry.
- **OPA**: policy-as-code when multiple enforcement points need the same decision contract.

Simple status, credential, queue and compatibility operations must not be routed through a heavier orchestrator or an LLM.

## Scoring

The deterministic SQL scorer combines:

- 30-day and 90-day frequency
- failure count
- exact duplicate count
- estimated token savings
- estimated time savings
- evidence volume
- deterministic execution bonus
- reversible execution bonus
- risk penalty
- posterior success from feedback

The score is a prioritization signal, not a scientific claim about intelligence.

## Promotion gates

A pattern can become active only when all are true:

- risk is low
- promotion score is at least 85
- CI passed
- E2E passed
- rollback specification exists
- verification specification exists
- named skill exists

High-risk and critical patterns cannot be automatically promoted.

The Pi-facing API exposes no promotion operation.

## Edge Function contract

Endpoint:

```text
https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/openclaw-pattern-engine
```

Authentication:

```text
Authorization: Bearer <pi-gateway-client JWT>
```

Actions:

- `status`
- `candidates`
- `resolve`
- `observe`
- `feedback`

Mutation requests require an execution key. Exact replay returns HTTP 409.

## E2E result

| Check | Result |
|---|---:|
| Unauthenticated request | 401 |
| Authenticated status | 200 |
| Capability resolution | 200 |
| Safe observation | 200 |
| Duplicate execution key | 409 |
| Secret-like payload | 400 |
| Executable payload field | 400 |
| Safe feedback | 200 |
| Temporary user and rows | removed |

## Security boundaries

- no credential value, provider key, service-role key or authorization header in evidence
- no arbitrary payload execution
- no second Telegram poller
- no automatic paid model fallback
- no automatic GitHub merge
- no automatic Production deployment
- no automatic deletion of Notion history
- no unauthorized account, device or network access
- no stealth persistence or policy bypass

## Physical completion

Cloud E2E does not prove physical Pi completion. The remaining evidence is:

1. Pi calls `status` with the existing scoped JWT.
2. Pi calls `resolve` for `status.read` and `runtime.compatibility`.
3. The host adapter reports Docker, systemd, OpenClaw, Tailscale and Ollama availability without returning secrets.
4. The result is stored as a secret-free completion receipt.
5. Telegram completes a real round trip through the existing single poller.
