# Pattern Research Provider Queue Policy

## Purpose

Keep the pattern-to-skill research queue useful without allowing disconnected
providers to create a permanent noisy backlog or silently fall through to an
unapproved network path.

## Connected providers

The live allowlist is read from `pattern_skill.research_worker` in Supabase.
The current enabled providers are:

- `github`: public repository metadata search only
- `internal_catalog`: existing reviewed and selected solutions already stored in Supabase

The following remain disabled until source-specific validation passes:

- `official_docs`
- `mcp_registry`
- `n8n_templates`
- `docker_hub`
- `manual`

## Queue behavior

`bridge_enabled_research_providers()` returns the current allowlist.

`bridge_enqueue_pattern_research()` creates new tasks only for providers in that
allowlist.

`bridge_reconcile_research_provider_queue()` applies two reversible rules:

1. A queued task for a disconnected provider becomes `blocked` with
   `PROVIDER_WORKER_NOT_CONNECTED`.
2. A task blocked for exactly that reason becomes `queued` again if the provider
   later enters the allowlist and the task still has attempts available.

Blocked tasks are retained for audit and future reactivation. They are not
reported as failures and are not deleted.

The reconciliation job runs hourly at minute 25:

```text
openclaw-pattern-provider-reconcile-v1
25 * * * *
```

The allowlisted metadata worker runs four times per hour:

```text
openclaw-pattern-research-worker-v1
6,21,36,51 * * * *
```

## GitHub credential boundary

The Supabase Edge research worker is pinned to:

```text
Github-api-delicate-key
```

Both available aliases passed read and search validation, but
`Github-api-delicate-key` was selected because it supplied the required public
metadata and search capability without the broader classic `repo` scope seen on
`GitHub-Classi-api-key`.

The broader alias remains valid but unselected. The worker never tests or uses
write permission, never increases scopes, and never returns the credential.

## Research boundary

The GitHub worker collects only repository metadata:

- repository name and URL
- description
- stars, forks, language and topics
- license identifier
- archived state
- default branch name
- pushed and updated timestamps

It does not download repository contents, README files, source archives,
workflows, releases or executable artifacts. It does not install a result,
select a result, activate a skill, merge a PR, deploy Production or use a paid
API.

## Current verified state

At the recorded checkpoint:

- completed tasks: 93
- blocked disconnected-provider tasks: 42
- queued tasks: 0
- claimed tasks: 0
- failed tasks: 0
- solution catalog entries: 54
- candidate-to-solution matches: 5
- temporary E2E users: 0

The blocked tasks are evenly retained for `official_docs`, `mcp_registry` and
`n8n_templates` and can be requeued automatically only after those providers
pass their own connection and policy gates.

## Non-goals

This policy does not enable arbitrary crawling, access-control bypass,
credential harvesting, covert infrastructure, unlicensed copying, automatic
paid usage, automatic installation, automatic skill activation, a second
Telegram poller, PR merge or Production deployment.
