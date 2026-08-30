---
name: durable-queue-retry
description: Preserve OpenClaw work through Supabase durable queues with idempotency, leases, bounded backoff and secret-safe receipts.
version: 1
status: verified
---

# Durable Queue Retry

## Owner

Supabase Queues/PostgreSQL is the single owner of durable work state. Do not add a second workflow engine for simple queue, retry, or short scheduling semantics.

## Fixed contract

1. Enqueue with a deterministic task or idempotency key.
2. Claim one allowlisted task with `FOR UPDATE SKIP LOCKED` and a bounded lease.
3. Execute a fixed handler; never execute commands from the payload.
4. Complete with a compact secret-free receipt, or fail with bounded backoff.
5. Reclaim only expired leases.
6. Preserve completed evidence; no automatic history deletion.

## Backoff

Use the task-specific bounded sequence. The current model retry sequence is:

`120 → 300 → 900 → 2700 → 7200` seconds.

## Safety boundaries

- service-role mutations remain server-side
- Pi receives a scoped JWT only
- secret-like evidence is rejected
- arbitrary payload execution is forbidden
- unknown task types fail closed
- second Telegram poller is forbidden
- paid model fallback is disabled
- automatic merge and Production deployment are disabled

## Verification

Verify duplicate enqueue reuse, single claim, lease expiry, bounded retry, completion receipt, rollback, RLS, and `secret_values_included=false`.
