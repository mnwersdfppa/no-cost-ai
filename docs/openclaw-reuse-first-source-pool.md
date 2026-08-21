# OpenClaw Reuse-First Infrastructure Pool

## Goal

Before creating new infrastructure, search the authoritative source catalog and reuse one verified owner for each intent. Supabase stores the machine state; this document is a human-readable projection.

## Selected roles

| Intent | Primary owner | Optional or reference layer | Decision |
|---|---|---|---|
| SSOT and exact deduplication | Supabase/PostgreSQL | pgvector after exact hash dedupe | Active |
| Durable work queue | Supabase Queues/PGMQ | Temporal only if distributed replay and SLA justify it | Active |
| Short periodic jobs | Supabase Cron | None by default | Active |
| Runtime and model routing | Existing OpenClaw Gateway + Supabase Guardian | Local Ollama after verified Pi heartbeat | Active |
| Portable OS/architecture validation | Docker Buildx/BuildKit | GitHub Actions matrix | Active cloud policy; physical Pi pending |
| Host service control | systemd/D-Bus fixed adapter | None | Candidate; Docker cannot own host control |
| External API fan-out | n8n | Supabase remains authoritative state | Candidate |
| Long interruptible agent state | LangGraph | Supabase queue for simpler workflows | Candidate |
| Telemetry normalization | Existing Supabase events, then OpenTelemetry | LangSmith optional | Candidate |
| Human-readable memory | Notion API | n8n may perform external upsert | Projection only |
| Structured capability discovery | Native APIs, then MCP | Direct model reasoning last | Approved |

## License classification

- Permissive official sources: Supabase components, PostgreSQL, pgvector, Docker Buildx, LangGraph, LangChain, Temporal, OpenTelemetry Collector, Node-RED, Prefect, Kestra.
- Open standard: Model Context Protocol.
- **n8n is source-available, not permissively open source for every use case.** Its relevant distribution terms include the **Sustainable Use License** and Enterprise License. Hosting, resale, white-labeling, embedding, and commercial redistribution require a separate license review before selection.
- Other source-available candidates, including mixed Windmill distributions, also remain behind a license gate.
- Managed or proprietary optional services: LangSmith and Notion API.
- Platform terms: GitHub Actions/API and project-native OpenClaw interfaces.

A source being publicly visible does not automatically permit resale, white-label hosting, redistribution, or embedding in another commercial service. License classification is part of solution scoring and cannot be bypassed by an automation macro.

## Research pipeline

For each pattern without an integrated primary source, Supabase generates three English queries:

1. Official GitHub and documentation search with API-first, ARM64, rollback and license terms.
2. Existing workflow/template search across Supabase, n8n, LangGraph, Docker and MCP.
3. Failure-recovery design search for bounded retries, deduplication, observability and approval gates.

The external researcher must prefer official documentation and official repositories. Public crawling must respect access controls, site terms and robots policy. Perplexity or another answer engine is optional and may only summarize sources that can be cited and independently verified.

## Docker boundary

Docker is used for portable workloads and validation across `linux/arm64` and `linux/amd64`.

Default container restrictions:

- read-only root filesystem
- non-root user
- `network=none` unless the test explicitly requires a network
- all capabilities dropped
- no new privileges
- no Docker socket
- no host PID namespace
- no host network
- read-only workspace mount
- temporary filesystem for scratch data

The following remain native host responsibilities:

- OpenClaw Gateway control
- systemd services and timers
- Tailscale daemon and device enrollment
- Ollama hardware acceleration
- the existing Telegram inbound poller

## Promotion policy

`active` requires score at least 85, low risk, CI pass, E2E pass, rollback, verification, and a named versioned skill. High-risk patterns cannot be automatically promoted.

## Prohibited paths

The system does not use piracy, unlicensed copying, stealth infrastructure, unauthorized access, access-control bypass, credential harvesting, malicious persistence, or concealed resource consumption. These are not fallback strategies.
