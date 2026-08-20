---
name: notion-ssot-projection-guard
description: Keep Supabase authoritative while preserving Notion as an additive human-readable projection and historical evidence surface.
---

# Notion SSOT Projection Guard

## Authority

Supabase owns machine state, fingerprints, queues, leases, promotion gates and execution receipts. Notion is not used as a lock, retry queue, credential store or current health source.

## Write order

```text
Supabase canonical commit
→ projection queue enqueue
→ Notion additive upsert
→ projected reference receipt
```

## Projection key

Every projection has a stable key, source reference and canonical payload hash.

- exact payload hash: reuse the existing projection
- changed payload: update the projection bound to the same projection key
- similar but different object: require review

## Migration

When reading historical Notion pages:

1. Record page ID, title, edit timestamp and classification.
2. Store a fingerprint of bounded metadata, not raw credentials.
3. Copy only canonical fields needed by the machine system.
4. Preserve the original page as historical evidence.
5. Mark migration as discovered, classified, staged, copied or verified.

## Forbidden actions

- no bulk deletion
- no silent overwrite of unrelated pages
- no automatic history removal
- no raw secret projection
- no machine completion claim based only on free-form Notion text

## Receipt

Return projection key, target page reference, payload hash, source reference, status, projected timestamp and `secret_values_included=false`.
