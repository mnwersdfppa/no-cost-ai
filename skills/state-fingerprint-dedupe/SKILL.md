---
name: state-fingerprint-dedupe
description: Prevent repeated OpenClaw records, retries and proposals by normalizing state, computing stable fingerprints and reusing exact prior results.
---

# State Fingerprint Deduplication

## Exact duplicate

1. Remove volatile timestamps, request IDs and presentation-only fields.
2. Preserve fields that change the decision, permission boundary, model route or expected result.
3. Canonicalize object keys and normalized identifiers.
4. Compute SHA-256 over the canonical representation.
5. Reuse the existing record, receipt or projection when the fingerprint matches.
6. Increment `occurrence_count` or `seen_count`; do not create another logical item.

## Similar duplicate

Similarity is not authority. A similar state is marked for review and is never silently merged when it may change permissions, costs, data ownership or user intent.

## Idempotency

Writes must use a stable execution key or unique constraint. Duplicate execution keys return the previous safe result or a bounded duplicate acknowledgement.

## Boundaries

- never hash raw secrets for display or evidence
- never include credentials in canonical payloads
- never delete historical Notion pages automatically
- never deduplicate across different users, projects or permission scopes without an explicit canonical key
- never treat an expired or failed receipt as proof of current success

## Receipt

Return fingerprint, duplicate class, reused reference, occurrence count, canonical source and `secret_values_included=false`.
