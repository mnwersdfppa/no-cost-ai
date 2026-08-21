# OpenClaw n8n External Macro Ownership

Status: `N8N_PRIMARY_WITH_SUPABASE_FAILOVER`

## Active owner

The deterministic Pi/PC-independent cron workload is owned by three published n8n Cloud workflows:

| Workflow | Schedule | Scope |
|---|---|---|
| `[EXTERNAL][ACTIVE] OpenClaw Recovery Core v1` | every 2 minutes | Queue maintenance, model retry, priority arbitration, recovery capability sync, recovery observer |
| `[EXTERNAL][ACTIVE] OpenClaw Pattern Core v1` | minute 7/22/37/52 | Pattern harvest, scoring, sync, skill sweep, dedupe and alias refresh |
| `[EXTERNAL][ACTIVE] OpenClaw Research Core v1` | minute 12/42 | Research query generation, canonicalization, expansion and bounded external workers |

## Single-owner rule

- n8n Cloud is the primary deterministic scheduler while its recovery heartbeat is fresh.
- Supabase Postgres remains the SSOT, durable queue and RPC execution plane.
- The five duplicate Supabase recovery Cron jobs are disabled after the first successful n8n scheduled receipt.
- `bridge_n8n_external_owner_watchdog_v1()` runs every five minutes.
- If the n8n recovery heartbeat is absent for more than eight minutes, the watchdog re-enables the five Supabase recovery Cron jobs.
- When n8n resumes, the watchdog disables those duplicate jobs again.

## Replaced legacy workflow

`ODI Pi Cron Migration Scheduler v1` was deactivated after the external workflows were published and the first recovery schedule receipt succeeded. Webhook-only Pi lease/completion compatibility gates remain available because they consume no schedule while idle.

## Framework placement

- **n8n:** deterministic schedules and external API macros.
- **Supabase:** durable state, queues, RPCs, receipts and automatic failover.
- **GitHub Actions:** code validation, Docker checks and PR evidence.
- **LangGraph:** reserved for long-running interruptible workflows after a persistent runtime is connected.
- **LangSmith:** reserved for tracing/evaluation after credentials are connected.
- **Google Cloud Workflows / Apps Script:** secondary failover candidate; not activated without an authenticated Google Cloud execution project.

This separation avoids duplicate schedulers and does not claim LangGraph, LangSmith or Google runtime activation without live credentials and execution evidence.

## Safety invariants

- No automatic reboot.
- No unknown-process kill.
- No paid model fallback.
- No second Telegram poller.
- No raw n8n API key in repository, workflow result or receipt.
