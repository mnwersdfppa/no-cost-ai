---
name: reuse-first-solution-composer
description: Search official APIs, skills, repositories and licensed components before creating new OpenClaw infrastructure.
version: 1
status: candidate
---

# Reuse-First Solution Composer

## Purpose

Reduce repeated reasoning and new-code risk by resolving a known pattern through an existing verified implementation whenever possible.

## Read-only API

```text
POST https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/openclaw-reuse-engine
Authorization: Bearer <scoped pi-gateway-client JWT>
```

Supported actions:

- `status`
- `sources`
- `reuse_queue`
- `research_queries`
- `projection_status`

The API cannot promote skills, claim queues, execute commands, expose credentials, merge pull requests, or deploy Production.

## Selection order

1. Existing project-native API or verified OpenClaw skill
2. Platform built-in capability already active in Supabase, GitHub, systemd, or the existing Gateway
3. Official open-source project with a recorded license and authoritative documentation
4. Source-available project after a license and redistribution gate
5. Optional managed service when it is not required for the free-plan path
6. A small deterministic adapter
7. New implementation only when the previous layers cannot satisfy the contract

## Research flow

1. Read the pattern candidate and its best current source match.
2. Reuse an `integrated` primary source immediately.
3. Validate an `approved` source in read-only CI or a hardened Docker matrix.
4. When no primary source exists, use the prepared English queries from `openclaw_research_queries`.
5. Search official documentation and official GitHub repositories first.
6. Record license, ARM64 support, API contract, resource cost, rollback, security boundaries, and adoption state.
7. Produce a source plan; do not install automatically.

## Tool ownership

- Supabase: SSOT, durable queue, scoring, research and projection state
- GitHub: official-source evidence, Draft PR source and CI
- Docker: portable ARM64/AMD64 validation only
- systemd host adapter: Gateway, timers, Tailscale and other host control
- n8n candidate: external API fan-out and human-facing integrations
- LangGraph candidate: genuinely long-running interruptible state graphs
- OpenTelemetry candidate: trace, metric and log normalization
- Notion: human-readable projection only
- Existing OpenClaw path: sole Telegram inbound poller

## License boundary

Treat n8n and mixed-license distributions such as Windmill separately from permissive open-source projects. Internal evaluation does not grant resale, white-label, redistribution, or hosted-service rights.

## Safety boundaries

- Authorized and auditable sources only.
- No unlicensed copying, piracy, access-control bypass, covert resource use, credential harvesting, or stealth persistence.
- Never use repository popularity as proof of safety.
- Never execute source code before license, provenance, secret scan, and rollback checks.
- Never mount the Docker socket, use privileged mode, or expose host networking by default.
- Never make a second tool the owner of an existing intent without a migration and rollback plan.

## Output receipt

Return:

- `pattern_key`
- `selected_source_key`
- `reuse_role`
- `license_name`
- `trust_tier`
- `supported_platforms`
- `validation_required`
- `new_code_required`
- `blocker`
- `next_action`
- `secret_values_included=false`
