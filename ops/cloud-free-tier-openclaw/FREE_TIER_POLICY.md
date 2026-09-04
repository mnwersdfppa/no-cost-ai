# OpenClaw Free-Tier Cloud Policy

Primary: Oracle A1 Docker
Edge: Cloudflare Workers
Backup: Cloudflare R2
SSOT: Supabase
Failover: existing AWS cbdfh only
Pi5: secondary worker
Windows: game only

## Guardrails
- Never create new AWS compute automatically.
- Oracle runtime must stay inside the account's actual Always Free allocation. Until console verification, enforce the conservative ceiling recorded in Supabase SSOT.
- Cloudflare Workers target: <= 100,000 requests/day and lightweight routing only.
- Cloudflare R2 target: <= 10 GB-month; use snapshots/config/brain continuity, not hot logs.
- One Telegram poller only.
- Preserve existing OpenClaw identity/state; do not onboard a new identity when the prior state is unavailable.
- Do not expose secret values in logs, CI, or receipts.

## Rollout
1. Verify Oracle tenancy/free allocation and existing A1 capacity.
2. Provision/reuse one A1 host only within Always Free.
3. Install Docker and mount existing OpenClaw state/workspace.
4. Start OpenClaw Gateway on 18789 and verify health.
5. Create Cloudflare Worker ingress with Oracle primary and Supabase continuity fallback.
6. Create R2 bucket for encrypted/non-secret recovery snapshots.
7. Switch Telegram ownership only after successful round-trip test.
8. Keep AWS cbdfh as cold fallback; do not create additional AWS instances.
