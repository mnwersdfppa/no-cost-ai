# LangGraph durable checkpoint through Supabase and GitHub OIDC

## State

`ACTIVE_PENDING_MAIN_E2E`

The external LangGraph runtime continues to execute on GitHub Actions. Its primary SQLite checkpoint is now mirrored to Supabase Postgres through a short-lived GitHub OIDC token.

## Ownership

- **n8n Cloud**: deterministic short schedules and API macros.
- **Supabase**: SSOT, durable queue, receipts, n8n failover, and LangGraph checkpoint storage.
- **GitHub Actions + LangGraph/LangChain**: interruptible orchestration and checkpointed decision flow.
- **LangSmith**: tracing when `LANGSMITH_API_KEY` is configured.
- **Google Cloud Workflows**: independent failover after GCP OIDC credentials are configured.

## Authentication

The workflow requests a GitHub OIDC token with audience:

```text
openclaw-supabase-langgraph
```

The Supabase Edge Function accepts only tokens whose claims match:

```text
repository = mnwersdfppa/no-cost-ai
workflow_ref = mnwersdfppa/no-cost-ai/.github/workflows/external-langgraph-orchestrator.yml@...
ref = refs/heads/main or refs/pull/...
issuer = https://token.actions.githubusercontent.com
audience = openclaw-supabase-langgraph
```

No long-lived Supabase service credential is stored in GitHub.

## Persistence order

1. Supabase Postgres checkpoint restored through GitHub OIDC.
2. GitHub cache used as a secondary restore layer.
3. LangGraph runs with `SqliteSaver`.
4. The resulting SQLite file is SHA-256 checked and persisted back to Supabase.
5. GitHub Artifact retains a secondary downloadable receipt.

## Safety

- Maximum checkpoint size: 2 MiB.
- Secret-like checkpoint content is rejected.
- Tables are RLS-enabled and revoked from `anon` and `authenticated`.
- Only the exact workflow identity can load or save checkpoints.
- The orchestration job remains read-only against OpenClaw control state.
- No model call, paid fallback, second Telegram poller, reboot, or unknown-process termination is introduced.
