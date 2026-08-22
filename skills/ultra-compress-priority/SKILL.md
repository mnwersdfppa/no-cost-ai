---
name: ultra-compress-priority
description: Auto-score repeated routing/automation requests, compress decision output, and choose zero-cost-first OpenClaw routes.
user-invocable: true
metadata: { "openclaw": { "requires": { "anyBins": ["python3"] }, "always": true } }
---

# Ultra Compress Priority

Use this skill automatically when the request mentions priority, scoring, ranking, S-rank absorption, cost reduction, token usage, inference speed, routing, automation, recurring work, OpenClaw, Raspberry Pi, Telegram, Supabase, GitHub, n8n, Make, Maton, Ollama, OpenRouter, or phone Codex.

## Execution

1. Run the scorer for nontrivial routing or priority decisions:

```bash
python3 {baseDir}/scripts/score.py "$USER_REQUEST"
```

2. Use the JSON result as the decision capsule. Do not expose hidden reasoning. Return only:

```text
score=<0-100> rank=<S|A|B|C|D> route=<route> reason=<short> next=<one action> blocked=<none|gate>
```

3. Preserve these hard boundaries:

- existing Telegram bot remains the single poller;
- paid OpenAI API automatic fallback is OFF;
- default free path is deterministic/local first, then Ollama `qwen2.5:3b`, then OpenRouter free, then STOP;
- phone Codex/ChatGPT OAuth is allowed only as the bounded S-rank high-value path already staged for the Pi phone bridge;
- no root, jailbreak, arbitrary shell, generic phone UI control, credential mutation, billing, deletion, merge, or deployment without a separate gate.

## Priority score

Use `{baseDir}/references/priority_matrix.yaml` as the score contract. High-frequency repeated requests should score high only when they are safe, deterministic, cheap, and useful.

Default score components:

- frequency: 0-25
- impact: 0-25
- latency gain: 0-15
- cost saving: 0-15
- determinism: 0-15
- safety bonus: 0-5
- risk penalty: 0 to -40
- context penalty: 0 to -10

## Route order

1. `cache_or_noop` — exact duplicate, status report, already prepared.
2. `deterministic` — Python, SQL, shell syntax, static checks, scoring, queue inspection.
3. `connector_read` — GitHub/Supabase/Linear/Gmail metadata read, no mutation.
4. `local_ollama_qwen25_3b` — low-risk summarization, classification, simple drafting.
5. `openrouter_free` — local model insufficient and free quota/model available.
6. `phone_codex_cli_gpt56_sol` — high-value reasoning through bounded phone OAuth path after T3/T4 gates.
7. `approval_gate` — paid API, credential change, destructive action, merge/deploy, phone write, second poller.

## Output compression

Default response: 3 lines maximum.

Expanded response only when the user asks for details, audit evidence, or a copy-paste command.

Never emit long rationale when the scorer returns `rank` below A; give one next action only.

## Verification

Run:

```bash
python3 {baseDir}/scripts/quick_validate.py {baseDir}
python3 {baseDir}/scripts/score.py "매일 반복 작업을 무료 모델로 자동화해줘"
```

The first command must print `VALID=1`. The second must output JSON with `rank`, `score`, `route`, and `capsule`.
