# Pattern-to-Skill Evolution Control Plane

## Objective

Turn repeated operational errors and repeated reasoning into versioned, testable,
reversible skills without allowing observations or queue payloads to become
executable commands.

The system is an engineering evolution loop, not an unrestricted self-modifying
agent:

```text
observe
  -> redact
  -> fingerprint
  -> deduplicate
  -> score
  -> translate once to a cached English query
  -> search existing official/open-source solutions
  -> select a bounded design
  -> sandbox
  -> evaluate
  -> canary
  -> activate
  -> monitor
  -> rollback or revise
```

## Canonical storage

Supabase is the operational single source of truth. Notion remains a readable
knowledge, planning, and archive layer.

Operational data is stored in:

- `bridge_pattern_observations`
- `bridge_pattern_candidates`
- `bridge_research_queue`
- `bridge_solution_catalog`
- `bridge_skill_registry`
- `bridge_skill_versions`
- `bridge_skill_evaluations`
- `bridge_automation_runs`
- `bridge_source_bindings`
- `bridge_capability_registry`

All of these tables have RLS enabled. Direct `anon` and `authenticated` table
access is revoked. Mutations are service-role-only and occur through bounded
Edge Functions or security-definer RPCs.

## Observation contract

The authenticated `pattern-observation-intake` Edge Function accepts only
bounded structured observations from `pi-gateway-client` or `pattern-observer`
identities.

It enforces:

- 16 KiB request body maximum
- 8 KiB context maximum
- action-bound execution-key idempotency
- per-user hourly rate limiting
- source and pattern-kind allowlists
- server-side SHA-256 fingerprint generation by default
- rejection of secret-like input
- no raw logs
- no queue-supplied command execution

The response returns only the fingerprint and non-secret scoring metadata.

## Priority scoring

Each fingerprint is scored using normalized 0–100 values:

```text
priority =
  0.24 * frequency
+ 0.08 * recency
+ 0.22 * user impact
+ 0.16 * repeated reasoning cost
+ 0.14 * automation fit
+ 0.06 * reversibility
+ 0.10 * confidence
- 0.18 * security risk
```

Actual Supabase events, completion gates, and work-queue errors are aggregated
from database records. Project-history estimates are stored separately and
explicitly marked as estimates rather than transcript-derived counts.

## Search before build

One English research query is cached per fingerprint. The research queue is
partitioned by provider:

1. official documentation
2. GitHub repositories
3. MCP registries and approved MCP servers
4. n8n templates and workflow patterns
5. the internal solution catalog

External candidates remain `discovered` until source freshness, license,
security, compatibility, and implementation cost are evaluated. Discovery does
not imply selection or deployment.

## Skill lifecycle

```text
observed
  -> proposed
  -> sandboxed
  -> validated
  -> canary
  -> active
  -> deprecated or blocked
```

Every skill has:

- an immutable version
- typed input and output schemas
- an explicit permission list
- required evaluation gates
- a rollback strategy
- audit receipts

The minimum gates are:

- static security
- deterministic E2E
- rollback

A low-risk skill can enter canary only when all gates pass. Activation requires
at least 30 minutes of canary time, at least three successful executions, and
zero failed or rolled-back executions during the canary interval.

Promotion changes registry metadata only. It never downloads or executes new
code.

## Automatic-promotion boundary

Only low-risk categories are eligible:

- validation
- deduplication
- bounded retry
- cache
- classification
- read-only API routing
- schema validation
- health checks
- reporting
- compatibility validation
- staged migration

The following permissions always require an explicit manual gate or remain
blocked:

- root or sudo
- arbitrary command execution
- credential-scope increase
- secret export
- public network exposure
- destructive deletion
- billing or paid API enablement
- Telegram inbound polling
- GitHub merge
- Production deployment
- Docker socket control
- privileged containers

## API-first capability routing

The preferred order is:

```text
existing typed API
  -> existing database RPC
  -> approved MCP tool
  -> fixed CLI or host adapter
  -> verified container contract
  -> cached skill
  -> bounded free-form reasoning
```

Writes require an idempotency key and a result receipt. Reasoning is a fallback,
not the default, when a deterministic capability already exists.

The capability registry currently distinguishes:

- Supabase RPC and Edge Functions
- GitHub Contents and Actions
- Docker Registry API
- Docker Engine API
- OpenClaw Gateway API
- Raspberry Pi fixed host adapter
- Notion API
- n8n workflow API
- LangGraph runtime
- LangSmith observability
- MCP adapters

A capability can be `discovered` without being trusted. Physical Pi and
credential-specific E2E evidence are required before selection.

## Docker compatibility policy

Docker is used for portable validation and dependency isolation, not as an
unbounded host controller.

Target platforms:

- `linux/arm64` for Raspberry Pi 5
- `linux/amd64` for CI and desktop validation

Container defaults:

- read-only root filesystem
- non-root user
- all Linux capabilities dropped
- `no-new-privileges`
- no Docker socket
- no host PID namespace
- no host network
- read-only workspace mount
- tmpfs for temporary files
- bounded CPU, memory, and PID limits

Systemd, Tailscale daemon enrollment, Ollama acceleration, OpenClaw gateway
control, and the existing Telegram inbound poller remain native host-adapter
responsibilities.

Docker Hub publisher credentials remain Supabase Edge-only and are never
embedded in the image or returned to Raspberry Pi.

Repository creation and multi-architecture image publication are separate
completion gates. The Docker skill becomes active only after anonymous public
pull, both target manifests, and a `sha256:` index digest are verified.

## Notion-to-Supabase migration

Migration order:

```text
discover
  -> classify
  -> stage
  -> copy
  -> checksum
  -> verify
  -> retain the source
  -> optional explicit archive
```

Operational state, error patterns, capability inventory, skill metadata, and
execution receipts belong in Supabase. Narrative documentation, planning,
meeting notes, and human-readable summaries may remain in Notion.

Notion pages are never automatically deleted. Secrets are not migrated through
this pipeline.

## Scheduled maintenance

`openclaw-pattern-skill-sweeper-v1` runs every 30 minutes. It:

- refreshes scores
- creates missing research tasks from cached English queries
- writes an idempotent automation receipt
- metadata-promotes eligible low-risk skills
- records successes and failures

It does not fetch arbitrary URLs or execute research results. A separate
read-only, source-allowlisted research worker remains a gated component.

## E2E evidence

The one-time pattern-control-plane E2E proved:

- unauthenticated intake: HTTP 401
- unauthenticated readiness: HTTP 401
- authenticated intake: HTTP 200
- server fingerprint returned
- duplicate execution key: HTTP 409
- secret-like content: HTTP 400
- authenticated read-only readiness: HTTP 200
- temporary identity, pattern, event, and ledger cleanup: zero remaining
- provider secret returned: false

The one-time probe was then retired with HTTP 410.

## Current deployment state

Cloud-side schema, scoring, registry, intake, readiness, scheduling, and
promotion boundaries are active. External research fetching, physical
Raspberry Pi installation, OpenClaw Gateway E2E, Tailscale enrollment, and the
real Telegram round trip remain separate evidence gates.

## Non-goals

This control plane does not implement:

- safeguard bypass or jailbreak behavior
- unauthorized access
- covert or hidden infrastructure
- credential theft or scope escalation
- arbitrary self-modifying code
- malware or biological-harm assistance
- automatic paid usage
- a second Telegram poller
- automatic PR merge or Production deployment
