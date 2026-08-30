# OpenClaw Pattern Evolution System

## Status

`CLOUD_ACTIVE_PHYSICAL_PI_PENDING`

Supabase is the authoritative machine-readable store. Notion is retained as a human-readable projection and historical-evidence surface. GitHub stores versioned schemas, skill contracts, CI and non-secret receipts. Raspberry Pi executes only bounded, verified actions and returns redacted receipts.

## Goal

Repeated errors, repeated reasoning and repeated operational decisions should become deterministic macros or versioned skills when doing so is cheaper, safer and more reliable than asking a language model to reason from the beginning each time.

This is an operational learning loop, not a claim that the system has reached AGI. Its value comes from reducing avoidable reasoning, preserving evidence and improving verified responses over time.

## Canonical loop

1. **Observe** — ingest a redacted event, error, queue result, Pi receipt or operator decision.
2. **Fingerprint** — generate a stable state fingerprint from the canonical pattern title, kind and error code.
3. **Deduplicate** — increment occurrence counts rather than creating repeated records.
4. **Score** — combine frequency, recency, impact, reasoning cost, automation fit, reversibility, confidence and risk.
5. **Translate** — create a bounded English research query when an existing translation is unavailable.
6. **Search before build** — prefer official documentation, official GitHub repositories, standards, MCP servers and verified workflow templates.
7. **Compose** — combine existing APIs or projects instead of creating an isolated replacement.
8. **Sandbox** — validate in CI, Docker or another isolated test environment.
9. **Evaluate** — require static security, schema validation, deterministic E2E and rollback evidence.
10. **Canary** — low-risk candidates run in a bounded canary state.
11. **Activate** — metadata-only promotion is permitted after the required successful canary receipts.
12. **Feedback** — record success, failure, latency, token savings and manual intervention.
13. **Rollback or upgrade** — failures quarantine the candidate or restore the prior version.

## Routing order

The router prefers the least expensive verified path:

1. verified native API
2. verified database RPC
3. verified MCP tool
4. verified account connector
5. deterministic macro
6. durable workflow
7. native host adapter
8. portable container
9. local model
10. free cloud model
11. manual review

A language model is used for translation, synthesis and genuinely ambiguous exceptions. It is not the default status checker, credential checker, queue poller or retry scheduler.

## Scoring

The current priority score is bounded to 0–100 and uses:

- frequency: 24%
- recency: 8%
- user impact: 22%
- estimated reasoning cost: 16%
- automation fit: 14%
- reversibility: 6%
- confidence: 10%
- security risk penalty: 18%

Scoring is deterministic SQL. It does not require an LLM.

## Promotion gates

Automatic promotion is limited to low-risk metadata transitions. It never installs arbitrary code by itself.

Required gates:

- `static_security`
- `deterministic_e2e`
- `rollback`
- any additional skill-specific gates
- no forbidden permissions
- current immutable skill version
- at least three successful canary runs
- zero failed or rolled-back canary runs
- at least 30 minutes in canary

The following permissions prevent automatic promotion:

- root or sudo
- arbitrary shell or code execution
- credential-scope changes
- secret export
- public-network exposure
- destructive data deletion
- billing or paid-API activation
- Telegram inbound polling
- automatic merge
- Production deployment
- Docker socket or privileged-container access

High-risk and critical candidates always require explicit review.

## Reuse-first research

English research tasks are generated only for candidates above the configured priority threshold. The search order is:

1. official product documentation
2. official source repository
3. open standards and MCP registries
4. verified n8n or workflow templates
5. established self-hosted projects
6. internal catalog
7. new implementation only after the prior paths are inadequate

Every selected source records its license class, trust tier, platforms, resource profile, integration contract, validation plan and rollback path.

## Supabase and Notion

### Supabase

Supabase owns:

- canonical pattern and skill state
- deduplication fingerprints
- queues and leases
- capability routing
- promotion gates
- feedback and receipts
- source-binding and projection state

### Notion

Notion remains useful for:

- human-readable dashboards
- historical pages
- navigation
- explanatory summaries
- approval and review notes

Migration policy:

- never bulk-delete historical pages
- never treat free-form Notion text as live machine state
- register the page ID and classification in Supabase
- copy only bounded canonical fields when useful
- use an idempotent projection key and payload fingerprint
- exact duplicates reuse the existing projection
- similar duplicates require review

The first indexed pages include Pi efficiency planning, the main dashboard, the standing-approval orchestrator and the second-brain memory architecture. Additional task, content-factory and voice-gateway pages remain in the bounded classification queue.

## Docker compatibility

Portable validation can use the public multiarchitecture image:

```text
docker.io/odifool/openclaw-compat:2026.08.20
sha256:6c6df789c26cb0400171818fb0903d27ff799f9642d6e8c2eaf2b1c8e2e2894b
```

Supported platforms:

- `linux/arm64` — Raspberry Pi 5
- `linux/amd64` — workstation or server

Default boundaries:

- non-root user
- read-only root filesystem
- all Linux capabilities dropped
- no new privileges
- no Docker socket
- no host PID namespace
- no host network
- no embedded credentials
- no Telegram poller

Systemd, Tailscale, Ollama acceleration, OpenClaw Gateway control and Telegram inbound polling remain native host responsibilities.

## APIs

- Pattern API: `openclaw-pattern-engine`
- Evolution readiness: `openclaw-evolution-readiness`
- Recovery readiness: `openclaw-recovery-readiness`
- Model gateway: `pi-model-gateway-guardian/v1`
- Pi work queue: `pi-work-queue`

Mutation APIs require the scoped `pi-gateway-client` identity, bounded payloads, execution keys and secret-like payload rejection. Promotion is not exposed as a public Edge action.

## Current active bridge skills

- `artifact-integrity-validator`
- `durable-queue-retry`
- `provider-failover-guardian`
- `runtime-compatibility-resolver`

Physical Raspberry Pi activation and Telegram T4 evidence remain separate completion gates. Cloud completion is never reported as physical completion.

## Non-negotiable boundaries

- no secret values in GitHub, Notion projections or receipts
- no second Telegram poller
- no provider key exported to Pi
- no automatic paid fallback
- no arbitrary queue-payload execution
- no hidden or covert infrastructure
- no automatic privilege escalation
- no automatic PR merge
- no Vercel Production deployment
- no biological, malware or other harmful operational capability
