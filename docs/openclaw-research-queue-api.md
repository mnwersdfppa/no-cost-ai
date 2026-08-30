# OpenClaw Research Queue API

## Purpose

`openclaw-research-queue` connects the deterministic pattern engine to bounded external research workers without giving those workers Supabase server credentials or AI-provider credentials.

Typical workers:

- ChatGPT with web and GitHub connectors
- a bounded n8n workflow
- a Raspberry Pi connector worker
- a future official-search provider adapter

The worker receives an English query and returns only an official source reference plus a bounded non-secret result summary. A returned result is **not automatically trusted or installed**. It remains review-gated.

## Authentication

Every request requires a Supabase access token whose user has:

```text
app_metadata.role = pi-gateway-client
```

The endpoint uses custom role verification and does not accept a Supabase service-role key from the client.

## Endpoint

```text
POST https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/openclaw-research-queue
```

## Actions

### `status`

Returns queue counts by state and provider. It does not return research queries or credentials.

```json
{
  "action": "status"
}
```

### `claim`

Atomically leases one due task. The lease is bounded to 1–60 minutes.

```json
{
  "action": "claim",
  "lease_minutes": 15
}
```

Returned task fields:

- `research_id`
- `candidate_id`
- pattern fingerprint and title
- provider class
- bounded English query
- priority and attempts
- lease deadline
- output contract

No provider API token is returned. The worker uses its own connected search or GitHub capability.

### `heartbeat`

Extends an owned lease by at most 30 minutes.

```json
{
  "action": "heartbeat",
  "research_id": "UUID",
  "extend_minutes": 10
}
```

### `complete`

Persists a bounded result reference and non-secret summary. Results are marked `reviewed=false`; selection and skill promotion occur later through separate gates.

```json
{
  "action": "complete",
  "research_id": "UUID",
  "result_ref": "official URL or connector reference",
  "result_count": 3,
  "result_summary": {
    "official_sources": 3,
    "license_review_required": true,
    "compatibility_review_required": true,
    "secret_values_included": false
  }
}
```

### `fail`

Requeues with bounded backoff or moves the task to `failed` when the attempt limit is reached.

```json
{
  "action": "fail",
  "research_id": "UUID",
  "error_code": "official_source_unreachable"
}
```

Backoff sequence:

```text
120 → 300 → 900 → 2700 → 7200 seconds
```

## Result boundary

The API rejects:

- secret-like strings
- Authorization headers
- access and refresh tokens
- API keys and passwords
- executable payload fields
- commands, shell, argv or source code
- oversized bodies or summaries
- completion or heartbeat for a task owned by another worker

Allowed results are metadata and source references only. Source review records license, trust, maintenance, platform compatibility, security and rollback evidence before selection.

## E2E evidence

The deployed API passed a scoped test covering:

- unauthenticated request rejected with HTTP 401
- authenticated status request
- atomic task claim
- bounded lease heartbeat
- safe completion and candidate transition
- `reviewed=false` result boundary
- unsafe result object rejected with HTTP 400
- no provider or server credential returned
- no arbitrary execution
- temporary identity and test rows removed

Completion gate:

```text
openclaw_research_queue_e2e = pass
```

## Non-goals

The endpoint does not:

- crawl the web by itself
- hold Perplexity, GitHub or search-provider credentials for workers
- execute discovered code
- install a repository or n8n template
- promote high-risk skills
- merge a PR or deploy Production
- create another Telegram poller

It is a safe queue and evidence boundary, not an unrestricted agent executor.
