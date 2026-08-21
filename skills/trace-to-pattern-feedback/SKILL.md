---
name: trace-to-pattern-feedback
description: Normalize bounded operational signals into secret-free rewards for the OpenClaw pattern promotion engine.
version: 1
status: candidate
---

# Trace-to-Pattern Feedback

## Purpose

Turn repeated success, failure, latency, rollback, and manual-intervention signals into deterministic pattern feedback without storing raw prompts, credentials, provider payloads, or unrestricted traces.

## Source order

1. Existing `bridge_events`, queue receipts, request ledger, and completion gates
2. OpenTelemetry Collector after a bounded Pi profile is verified
3. LangSmith only as an optional managed evaluation service; never as a required free-plan dependency

## Normalized reward contract

- `succeeded`: positive reward from 0 to 1
- `failed`, `blocked`, `rolled_back`, `cancelled`: reward from -1 to 0
- Record latency and token counts only when measured.
- Record `manual_intervention=true` when a person changed the result.
- Deduplicate by `pattern_key + execution_key`.

## Cardinality and retention

- Use known pattern keys, skill names, versions, error codes, and outcome enums.
- Reject arbitrary labels and unbounded stack traces.
- Aggregate before long-term Supabase retention.
- Preserve a compact receipt; raw traces use a short retention window.

## Safety boundaries

- Redact and reject access tokens, refresh tokens, private keys, provider keys, Authorization headers, command strings, scripts, and executable paths.
- Never convert an observation directly into code execution.
- Never raise a skill to `active` from telemetry alone.
- Never send private operational data to an optional external service without a separate permission and retention gate.

## Promotion use

Feedback changes posterior success and evidence. It does not bypass the score, CI, E2E, low-risk, rollback, verification, and named-skill requirements.

## Output

`pattern_key`, `execution_key`, `outcome`, `reward`, `latency_ms`, `manual_intervention`, `skill_version`, `error_code`, `secret_values_included=false`.
