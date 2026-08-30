---
name: pattern-evolution
description: Route repeated OpenClaw work through the live Supabase pattern registry, deterministic APIs, bounded retries, evidence gates, and reversible skill promotion before using expensive model reasoning.
metadata:
  version: "1.1.0"
  canonical_ssot: "Supabase public.bridge_* + public.openclaw_*"
  readiness_rpc: "public.openclaw_pattern_engine_bundle_readiness_v1"
---

# Pattern Evolution

Use this skill when a request, error, recovery step, status check, or integration decision appears more than once.

## Required order

1. Read current state through an approved API, MCP tool, or the Supabase readiness RPC.
2. Generate a stable, redacted state fingerprint before creating work.
3. Reuse an active deterministic skill or adapter when its input contract and evidence match.
4. Use bounded retry and provider failover only through the registered queue policy.
5. Search official documentation, maintained repositories, and approved template catalogs before writing a new implementation.
6. Promote only after static security, deterministic replay, shadow or canary evidence, and rollback checks pass.
7. Store machine state in Supabase; publish only human-readable projections to Notion or Linear.
8. Record a non-secret receipt for every state-changing action.

## Routing ladder

`verified API/MCP -> deterministic skill -> bounded workflow -> low-cost classifier -> deliberative agent -> human approval`

Do not call an LLM for an exact status query, model-list check, queue operation, duplicate detection, retry decision, artifact hash check, or known recovery procedure.

## Hard boundaries

- No arbitrary shell generated from model output.
- No automatic paid-model fallback.
- No second Telegram inbound poller.
- No secret, JWT, OAuth token, API key, or authorization header in evidence.
- No automatic merge, production deployment, credential-scope expansion, destructive change, or high-risk promotion.
- No hidden infrastructure, access-control bypass, stealth persistence, malware, or biological-threat assistance.

## Completion contract

Report `complete` only when the relevant live receipt exists. Cloud preparation does not equal physical Raspberry Pi completion. A Pi/OpenClaw deployment remains pending until installer, model, worker, Telegram round-trip, and rollback receipts are present.
