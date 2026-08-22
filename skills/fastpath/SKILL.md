---
name: fastpath
description: Score routine requests for the cheapest safe path; prefer cache, deterministic code, local/free models, and compact context before escalation.
user-invocable: true
---

# FastPath

Use this skill automatically for routine, repeated, status, classification, extraction, normalization, short summarization, low-risk automation, and any request emphasizing speed, token savings, or cost efficiency.

## Goal

Minimize latency and model-token use without lowering correctness or bypassing safety. Do not expose or store hidden chain-of-thought. Keep only a compact decision capsule when useful:

`fastpath=<L0-L4> score=<0-100> why=<short observable reason>`

Do not emit the capsule unless it helps debugging or the user asks.

## Fast-path score

Score only observable request properties:

- repeat/cache potential: 0-25
- deterministic structure: 0-20
- low-risk/reversible: 0-20
- short relevant context: 0-15
- stable/no freshness requirement: 0-10
- no side effect required: 0-10

Total: 0-100.

Hard caps:

- destructive, payment, credential/security mutation: max 10 and require explicit approval
- medical/legal/financial high-stakes: max 35 and verify authoritative sources
- current/latest/price/news/weather/status that can change: max 65 until refreshed
- repeated failure or confidence below 80%: escalate one lane

## Route

| Score | Lane | Default action |
|---:|---|---|
| 90-100 | L0 | cache, exact lookup, parser, regex, SQLite, shell/Python; no LLM if possible |
| 75-89 | L1 | local small model via Ollama/llama.cpp; compact prompt |
| 60-74 | L2 | free or already-paid subscription route; bounded output |
| 40-59 | L3 | stronger model with only goal + constraints + fresh evidence |
| 0-39 | L4 | strong model + tool/source verification; approval gate for side effects |

Never silently fall back to a paid API because a cheaper lane failed.

## High-frequency priority

Use these as fast-path suitability priors, then apply caps above:

- exact repeat / stable cache hit: 100
- health/status read-only check: 98
- routing/classification: 97
- extraction/normalization: 95
- deterministic formatting/transformation: 93
- short summary: 91
- local memory/file lookup: 88
- fresh web/API lookup: 78
- low-risk tool action: 74
- multi-step planning: 62
- code generation/patching: 55
- high-stakes advice: 25
- destructive/payment/credential mutation: 0

## Context compression

Before any L1-L4 model call, keep only:

1. `GOAL` — one sentence
2. `CONSTRAINTS` — maximum 5 bullets
3. `EVIDENCE` — only the latest relevant tool/file results
4. `NEXT` — one requested output/action

Drop duplicated history, repeated explanations, stale errors, and already-settled alternatives. Retrieve narrow file ranges instead of whole documents. Batch independent lookups in one tool call when supported.

## Token/output budget

- L0: 0 model tokens
- L1: target <=256 output tokens
- L2: target <=512 output tokens
- L3: target <=768 output tokens
- L4: expand only as required for correctness

For status checks, prefer 1-3 lines. For tool workflows, report changed / blocked / next only.

## Cost-efficient stack

Prefer capability absorption over adding heavy infrastructure:

1. Python stdlib + SQLite/cache for deterministic/high-frequency work
2. OpenClaw skill routing for automatic activation
3. Ollama local small model when semantics are required
4. llama.cpp as a lightweight local runtime alternative
5. free/provider-subscription route only when local is insufficient
6. paid API only by explicit policy/approval

Do not add LiteLLM, vLLM, Redis, vector DBs, or additional gateways unless measured traffic justifies the extra process, memory, and maintenance cost.

## Execution rule

If a task can be completed safely in a cheaper lane, do not escalate. If a required fact is current, risky, uncertain, or side-effecting, escalate immediately instead of forcing the fast path.
