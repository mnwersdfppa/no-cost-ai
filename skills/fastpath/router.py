#!/usr/bin/env python3
import argparse
import json
import re

SIMPLE = re.compile(r"\b(status|check|health|summary|summarize|classify|extract|normalize|format|translate|verify)\b|상태|확인|점검|요약|분류|추출|정규화|정리|번역", re.I)
REPEAT = re.compile(r"\b(again|same|repeat|reuse|cached?)\b|다시|같은|반복|재사용|캐시", re.I)
FRESH = re.compile(r"\b(latest|today|current|news|price|weather|score|schedule|version)\b|최신|오늘|현재|뉴스|가격|날씨|점수|일정|버전", re.I)
HIGH_STAKES = re.compile(r"\b(medical|legal|financial|diagnosis|prescription|investment|tax)\b|의료|법률|금융|진단|처방|투자|세금", re.I)
DESTRUCTIVE = re.compile(r"\b(delete|drop|erase|format|uninstall|purchase|pay|credential|password|secret|token|reboot|shutdown)\b|삭제|초기화|포맷|제거|결제|구매|자격증명|비밀번호|비밀키|토큰|재부팅|종료", re.I)
SIDE_EFFECT = re.compile(r"\b(send|create|update|change|deploy|merge|install|restart|execute|run)\b|전송|생성|수정|변경|배포|병합|설치|재시작|실행", re.I)
CREATIVE = re.compile(r"\b(brainstorm|creative|story|novel|design concept)\b|브레인스토밍|창의|소설|스토리", re.I)

PRIORS = [
    ("exact_repeat_cache", REPEAT, 100),
    ("health_status_readonly", re.compile(r"\b(status|health|check)\b|상태|점검|확인", re.I), 98),
    ("routing_classification", re.compile(r"\b(route|classify|categorize)\b|라우팅|분류", re.I), 97),
    ("extraction_normalization", re.compile(r"\b(extract|normalize|parse)\b|추출|정규화|파싱", re.I), 95),
    ("deterministic_transform", re.compile(r"\b(format|convert|translate)\b|형식|변환|번역", re.I), 93),
    ("short_summary", re.compile(r"\b(summary|summarize)\b|요약", re.I), 91),
    ("fresh_lookup", FRESH, 78),
    ("multi_step_planning", re.compile(r"\b(plan|strategy|roadmap)\b|계획|전략|로드맵", re.I), 62),
    ("code_generation_patch", re.compile(r"\b(code|patch|refactor|debug)\b|코드|패치|리팩터|디버그", re.I), 55),
]


def classify(text: str) -> dict:
    repeat = bool(REPEAT.search(text))
    simple = bool(SIMPLE.search(text))
    fresh = bool(FRESH.search(text))
    high_stakes = bool(HIGH_STAKES.search(text))
    destructive = bool(DESTRUCTIVE.search(text))
    side_effect = bool(SIDE_EFFECT.search(text))
    creative = bool(CREATIVE.search(text))

    dims = {
        "repeat_cache_potential": 25 if repeat else (12 if simple else 5),
        "deterministic_structure": 20 if simple and not creative else (8 if not creative else 2),
        "low_risk_reversible": 20 if not (high_stakes or destructive) else (5 if high_stakes else 0),
        "short_relevant_context": 15 if len(text) <= 1500 else (8 if len(text) <= 5000 else 2),
        "stable_no_freshness": 10 if not fresh else 0,
        "no_side_effect": 10 if not side_effect else 0,
    }
    score = sum(dims.values())

    prior_name, prior_score = "general", score
    for name, pattern, value in PRIORS:
        if pattern.search(text):
            prior_name, prior_score = name, value
            break
    score = round((score * 0.7) + (prior_score * 0.3))

    flags = []
    if destructive:
        score = min(score, 10); flags.append("destructive_or_credential_or_payment")
    if high_stakes:
        score = min(score, 35); flags.append("high_stakes")
    if fresh:
        score = min(score, 65); flags.append("freshness_required")

    if score >= 90:
        lane, provider, out = "L0", "deterministic", 0
    elif score >= 75:
        lane, provider, out = "L1", "local_small", 256
    elif score >= 60:
        lane, provider, out = "L2", "free_or_subscription", 512
    elif score >= 40:
        lane, provider, out = "L3", "strong_compact", 768
    else:
        lane, provider, out = "L4", "strong_verified", 1024

    return {
        "score": score,
        "lane": lane,
        "provider_alias": provider,
        "priority_prior": prior_name,
        "max_output_tokens": out,
        "flags": flags,
        "dimensions": dims,
        "chain_of_thought_stored": False,
        "paid_api_automatic_fallback": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Deterministic OpenClaw FastPath request scorer")
    parser.add_argument("text", nargs="*", help="request text; stdin is used when omitted")
    args = parser.parse_args()
    text = " ".join(args.text).strip()
    if not text:
        import sys
        text = sys.stdin.read().strip()
    print(json.dumps(classify(text), ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
