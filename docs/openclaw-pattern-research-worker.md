# OpenClaw Canonical Pattern Research Worker

## Purpose

Convert repeated operational errors and repeated reasoning into reusable solution
candidates without executing discovered code.

This worker is part of the evolution loop:

```text
observe
  -> fingerprint
  -> deduplicate
  -> score
  -> cache one English query
  -> search existing sources
  -> record metadata candidates
  -> review license and maintainers
  -> validate in CI or a hardened container
  -> propose a versioned skill
  -> canary
  -> activate or roll back
```

## Canonical ownership

`openclaw_research_queries` is the only canonical research-query queue.

`bridge_research_queue` remains a compatibility intake surface. Queued bridge
rows are mapped to one canonical query and then marked completed with
`canonical_query_id`, `delegated_at`, and
`delegation_reason=canonical_openclaw_research_queries`.

One canonical query is expanded into one
`openclaw_research_source_runs` row per source scope. This prevents the same
English query from being executed independently by two queue systems.

## Enabled sources

The first worker version processes only:

- `internal_catalog`
- `official_github`

Other source scopes remain recorded for later source-specific workers. They are
not silently treated as completed.

## GitHub boundary

GitHub processing uses the repository search API and stores metadata only:

- repository full name and URL
- description and topics
- stars, forks, open issues, default branch, and last push time
- GitHub-reported SPDX license metadata
- deterministic query-overlap and maintenance scores

It does not:

- clone repositories
- download source archives
- fetch or execute README instructions
- run repository scripts
- install packages
- create a merge
- deploy to Production

A discovered repository is stored as `research_only` with community trust until
license, maintainer, static-security, compatibility, and rollback checks pass.

## Internal catalog boundary

Internal catalog research compares the cached English query against already
registered solution names, capabilities, and workload tags. It writes or
refreshes `openclaw_pattern_source_matches` metadata.

A database trigger prevents a new search from downgrading an existing
`approved`, `integrated`, or `rejected` decision. Primary and secondary reuse
roles are also preserved, and match scores are monotonic.

## Authentication

The Edge Function is invoked with a random bearer stored in Supabase Vault.
Only the SHA-256 digest is compared by the verification RPC. The raw worker
bearer is never stored in canonical configuration or returned by the API.

A validated GitHub Edge credential may be used for public repository-search
rate limits. If no validated token is available, the worker uses the public
GitHub API within its anonymous rate limit. The credential is never returned or
written to research results.

## Scheduling and limits

```text
schedule: 5,20,35,50 * * * *
maximum tasks per invocation: 2
maximum GitHub results per task: 5
lease: 10 minutes
maximum attempts per source run: 3
```

Retries use bounded database state. Stale leases are released without executing
queue payloads as commands.

## Promotion boundary

Research results cannot activate a skill. The path remains:

```text
candidate metadata
  -> source/license review
  -> static security
  -> deterministic E2E
  -> rollback evidence
  -> optional architecture/container validation
  -> canary
  -> active
```

Automatic promotion is metadata-only and limited to low-risk skills. Root,
sudo, arbitrary execution, credential-scope changes, secret export, public
network exposure, deletion, billing, paid APIs, Telegram inbound polling,
Docker-socket control, privileged containers, merge, and Production deployment
remain outside automatic promotion.

## E2E result

The one-time E2E proved:

- unauthorized worker call: HTTP 401
- Vault-authenticated invocation: accepted
- high-priority internal-catalog source run: atomically claimed
- result count: positive
- source run: completed
- existing reviewed source matches: not downgraded
- repository content downloaded: false
- README executed: false
- automatic install: false
- automatic merge: false
- arbitrary code execution: false
- provider credential returned: false
- temporary query and source-run rows after cleanup: zero

The one-time E2E and temporary-user cleanup endpoints were then retired with
HTTP 410.

## Physical Pi status

This worker is cloud-side and does not complete the physical Raspberry Pi gate.
The Pi still must run the SHA-pinned current master installer and produce real
OpenClaw Gateway, systemd timer, outbound Telegram, and T4 round-trip receipts.
