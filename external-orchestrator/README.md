# External orchestration layer

## Active ownership

- **n8n Cloud:** deterministic schedules and external API macros
- **Supabase:** SSOT, durable queue, RPCs, receipts, and automatic failover
- **GitHub Actions + LangGraph/LangChain:** durable read-only orchestration, checkpointing, validation, and incident reporting
- **LangSmith:** tracing auto-enables only when `LANGSMITH_API_KEY` is configured
- **Google Cloud Workflows:** definition is published; deployment auto-runs only when the three GCP OIDC secrets exist

The GitHub LangGraph runtime never mutates Supabase. It reads a public-safe readiness RPC and emits a checkpointed receipt. Mutating handoff decisions remain inside Supabase and n8n.

## Local scheduler handoff

Once external ownership and rollback readiness are verified, Supabase arms the task:

```text
external-local-scheduler-disable-v1
```

The local scripts disable only project-owned schedules matching OpenClaw/ODI/n8n/LangGraph. They preserve OpenClaw Gateway and Tailscale services and always create rollback backups first.
