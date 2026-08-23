# FastPath — S-rank decision compression

FastPath is an OpenClaw workspace skill for routine/high-frequency work. It reduces model calls by scoring the request first and using the cheapest safe lane.

## Why this stack

The highest ROI path on a Raspberry Pi is not another orchestration service. It is:

1. deterministic Python/SQLite first — zero model tokens
2. OpenClaw skill activation — no extra daemon
3. Ollama local small model — semantic work without external token billing
4. llama.cpp alternative — lightweight local runtime when preferred
5. free/already-paid subscription route — only when local is insufficient
6. strong/paid model — explicit escalation only

Heavy gateways such as LiteLLM/vLLM, Redis, vector databases, and extra MCP layers are deferred until measured traffic justifies them. This avoids paying latency, RAM, maintenance, and failure-surface costs before they produce value.

## High-frequency scores

| Work type | Fast-path prior |
|---|---:|
| exact stable repeat/cache | 100 |
| health/status read-only | 98 |
| routing/classification | 97 |
| extraction/normalization | 95 |
| deterministic transformation | 93 |
| short summary | 91 |
| local memory/file lookup | 88 |
| current/fresh lookup | 78 |
| low-risk tool action | 74 |
| multi-step planning | 62 |
| code generation/patch | 55 |
| high-stakes advice | 25 |
| destructive/payment/credential mutation | 0 |

The prior is not a safety score. Freshness, risk, and side effects cap the final score.

## Expected effect

- repeated/status/extraction work: often L0, no model tokens
- routine semantic work: L1 local model with <=256 output tokens
- external calls: only when the result requires freshness or stronger capability
- hidden chain-of-thought is never stored as telemetry
- paid API fallback is never automatic

## Install

```bash
cd skills/fastpath
bash install.sh
```

OpenClaw officially loads custom skills from `~/.openclaw/workspace/skills/<skill>/SKILL.md`; after installation the script verifies discovery and restarts the Gateway if needed.

## Manual scorer test

```bash
python3 router.py "check OpenClaw gateway status"
python3 router.py "latest BTC price"
python3 router.py "delete production credentials"
```

The output contains score/lane/flags only. It does not contain private reasoning.
