#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from hashlib import sha256

TEXT = " ".join(sys.argv[1:]).strip() or sys.stdin.read().strip()
LOW = TEXT.lower()

PATTERNS = {
    "recurring": r"매일|매주|반복|자동|예약|cron|schedule|workflow|n8n|make|webhook|계속|상시",
    "pipeline": r"openclaw|오픈클로|라즈베리|telegram|텔레그램|bridge|브릿지|mcp|supabase|github|pr|흡수|s-?rank|s랭크",
    "cost": r"무료|가성비|토큰|비용|과금|openrouter|ollama|qwen|local|zero-cost|cheap|free",
    "speed": r"빠르게|속도|latency|초압축|압축|short|간결|경량|캐시|cache",
    "deterministic": r"점수|score|검증|validate|정적|sql|status|상태|확인|lint|ci|queue|큐",
    "risk": r"결제|billing|유료|secret|비밀|토큰값|key|credential|삭제|delete|merge|deploy|배포|root|jailbreak|탈옥|루팅|shell|tap|swipe|poller",
    "write": r"수정|생성|등록|적용|반영|write|create|update|deploy|merge|delete|send|발송",
}

def hit(name: str) -> bool:
    return re.search(PATTERNS[name], LOW, re.I) is not None

frequency = 25 if hit("recurring") else 15 if len(TEXT) > 240 else 5
impact = 25 if hit("pipeline") else 16 if hit("write") else 6
latency = 15 if hit("speed") else 8 if hit("deterministic") else 3
cost = 15 if hit("cost") else 8 if "model" in LOW or "모델" in LOW else 0
determinism = 15 if hit("deterministic") else 9 if hit("recurring") else 2
safety = 5 if not hit("write") else 3
penalty = 0
if hit("risk"):
    penalty -= 25
if re.search(r"결제|billing|paid api|유료 api", LOW):
    penalty -= 15
if re.search(r"삭제|delete|merge|deploy|배포|root|jailbreak|탈옥|루팅|second poller|두 번째", LOW):
    penalty -= 15
if len(TEXT) > 1800:
    penalty -= 10

score = max(0, min(100, frequency + impact + latency + cost + determinism + safety + penalty))
rank = "S" if score >= 85 else "A" if score >= 70 else "B" if score >= 55 else "C" if score >= 35 else "D"

if penalty <= -35:
    route = "approval_gate"
elif hit("deterministic") or hit("speed"):
    route = "deterministic"
elif hit("pipeline") and hit("write"):
    route = "connector_read_then_draft_pr"
elif hit("cost"):
    route = "local_ollama_qwen25_3b_then_openrouter_free_then_stop"
elif rank == "S":
    route = "phone_codex_cli_gpt56_sol_after_gates"
elife = None
if route if False else False:
    pass

reason_parts = []
for label, enabled in [
    ("freq", frequency >= 20),
    ("impact", impact >= 20),
    ("speed", latency >= 12),
    ("cost", cost >= 12),
    ("det", determinism >= 12),
    ("risk", penalty < 0),
]:
    if enabled:
        reason_parts.append(label)
reason = "+".join(reason_parts) or "low-signal"
blocked = "gate" if route == "approval_gate" else "none"
next_action = {
    "approval_gate": "ask_for_specific_boundary_approval",
    "deterministic": "run_static_or_queue_check_first",
    "connector_read_then_draft_pr": "read_status_then_prepare_draft_only",
    "local_ollama_qwen25_3b_then_openrouter_free_then_stop": "use_free_route_before_any_paid_model",
    "phone_codex_cli_gpt56_sol_after_gates": "verify_T3_T4_before_claiming_live",
}.get(route, "answer_in_3_lines")

capsule = f"score={score} rank={rank} route={route} reason={reason} next={next_action} blocked={blocked}"
print(json.dumps({
    "score": score,
    "rank": rank,
    "route": route,
    "reason": reason,
    "blocked": blocked,
    "next": next_action,
    "capsule": capsule,
    "request_sha256_12": sha256(TEXT.encode("utf-8", "ignore")).hexdigest()[:12],
}, ensure_ascii=False, separators=(",", ":")))
