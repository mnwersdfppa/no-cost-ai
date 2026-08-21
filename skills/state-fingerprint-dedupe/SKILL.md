---
name: state-fingerprint-dedupe
description: Prevent repeated OpenClaw records, retries and proposals by normalizing state, computing stable fingerprints and reusing exact prior results.
---

# State Fingerprint Deduplication

## Exact duplicate

1. Remove volatile timestamps, request IDs and presentation-only fields.
2. Recursively replace secret-bearing keys and secret-like strings with `<redacted>` before hashing.
3. Preserve fields that change the decision, permission boundary, model route or expected result.
4. Canonicalize JSON object keys and normalized identifiers.
5. Compute SHA-256 over namespace, normalizer version and canonical JSONB.
6. Reuse the existing record when the fingerprint matches.
7. Increment `seen_count`; do not create another logical item.

## Similar duplicate

Similarity is not authority. A state whose decision-relevant value differs receives a different fingerprint and is preserved. Semantic similarity may create a review candidate later, but it never silently merges records or deletes history.

## Supabase contract

Authoritative table:

```text
bridge_state_fingerprints
```

Service-role RPC:

```text
bridge_upsert_state_fingerprint(
  namespace,
  payload,
  source_ref,
  ignore_keys,
  normalizer_version
)
```

Authenticated Edge Function:

```text
POST /functions/v1/state-fingerprint-dedupe
```

Required identity roles:

```text
pi-gateway-client
pattern-observer
```

Request:

```json
{
  "execution_key": "stable-request-key",
  "namespace": "openclaw.gateway",
  "source_ref": "gateway-status",
  "payload": {
    "service": "gateway",
    "status": "ready",
    "updated_at": "volatile"
  }
}
```

Response returns only fingerprint metadata. The canonical payload, source references, JWT and service-role key are not returned.

## Fixed normalization policy

Volatile keys ignored by default:

```text
updated_at
created_at
timestamp
observed_at
nonce
request_id
correlation_id
trace_id
span_id
```

The API does not permit callers to supply a custom ignore-key list. Changes to normalization require a new version and migration.

Allowed namespace prefixes:

```text
openclaw
pi
telegram
docker
mcp
n8n
notion
memory
workflow
system
integration
artifact
credential
```

## Idempotency and rate limiting

- every write requires an action-bound execution key
- duplicate execution keys return HTTP 409
- the default rate limit is 240 requests per user per hour
- state payload maximum is 24 KiB
- request body maximum is 32 KiB

## Verified E2E

The live Edge E2E proved:

- unauthenticated request: HTTP 401
- first state: HTTP 200
- reordered exact replay: same fingerprint and `seen_count=2`
- decision-relevant change: different fingerprint and preserved row
- duplicate execution key: HTTP 409
- secret-like request: HTTP 400
- canonical payload returned: false
- temporary users, ledger rows, events and state rows remaining: zero

## Promotion boundary

The skill may automatically enter canary only when all required evaluations pass. Activation requires:

- static security pass
- schema validation pass
- deterministic E2E pass
- rollback pass
- secret-boundary pass
- at least 30 minutes in canary
- at least three successful canary runs
- zero canary failures or rollbacks

Promotion changes registry metadata only. It does not execute arbitrary code, change credential scopes, merge a pull request or deploy Production.

## Rollback

1. Disable the `supabase.state_fingerprint_dedupe` capability route.
2. Disable the Edge Function route or remove it from the Pi capability map.
3. Preserve existing fingerprint rows for audit unless an explicit scoped deletion is approved.
4. Revert to the previous normalizer version; never rewrite historical fingerprints in place.

## Boundaries

- never hash raw secrets for display or evidence
- never return canonical payloads through the public API
- never include credentials in Notion or GitHub receipts
- never delete historical Notion pages automatically
- never deduplicate across different namespaces, users, projects or permission scopes without an explicit canonical key
- never automatically merge semantically similar states
- never treat an expired or failed receipt as proof of current success

## Receipt

Return fingerprint, exact-duplicate flag, `seen_count`, normalizer version and `secret_values_included=false`.
