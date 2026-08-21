# OpenClaw Pattern Evolution Engine v1.1.0 — Execution Handoff

Status: `LIVE_SUPABASE_AND_DRAFT_PR_READY_PHYSICAL_PI_PENDING`

This document resolves the four questions in `PROJECTS.md`. Do not ask the operator for these values again unless live evidence contradicts them.

## 1. Supabase live migration

- **Source:** the existing live Supabase control plane, not a local dump and not another cloud project.
- **Target project ref:** `dpllasnpfskyyyzebyal`.
- **Scope:** schema reconciliation and non-secret control-plane metadata only. No bulk data copy and no auth-user migration.
- **Strategy:** idempotent custom SQL that reuses `public.bridge_*` and `public.openclaw_*`; do not create a duplicate `guardian` SSOT.
- **Migration:** `supabase/migrations/20260820103000_reconcile_live_pattern_engine_v1_1_0.sql`.
- **Downtime:** zero downtime; additive function/config/receipt changes only.
- **Live result:** applied and verified. Readiness RPC: `public.openclaw_pattern_engine_bundle_readiness_v1()`.
- **Required tables:** 14/14 present at verification.

## 2. GitHub Draft PR

- **Repository:** `mnwersdfppa/no-cost-ai`.
- **Feature branch:** `feat/supabase-emergency-bridge-20260819`.
- **Base branch:** `main`.
- **Draft PR:** `#5`.
- **Purpose:** preserve cloud recovery, model routing, Telegram single-poller policy, pattern evolution skill, n8n inactive workflow, and physical Pi installer behind evidence gates.
- **Do not:** create a second PR, merge automatically, force-push, deploy production, or create proof-only commits.
- **New reviewed paths:**
  - `skills/pattern-evolution/SKILL.md`
  - `n8n/pattern-event-ingest.workflow.json`
  - `supabase/migrations/20260820103000_reconcile_live_pattern_engine_v1_1_0.sql`
  - `pi/install-openclaw-pattern-engine-v1.1.0.sh`

## 3. n8n import

- **Source:** `n8n/pattern-event-ingest.workflow.json` in the Draft PR branch.
- **Target:** the existing Pi-local/self-hosted n8n instance.
- **Cloud target warning:** `https://api.n8n.io/api` is the public template catalog, not the operator's n8n instance API. Do not send import requests to it.
- **Secret handling:** `OPENCLAW_PATTERN_INGEST_TOKEN` environment variable. Do not commit or print the value.
- **Import behavior:** import once and keep `active=false`.
- **Conflict policy:** an installer marker prevents repeat import on the same host; multiple detected n8n containers block automatic selection.
- **Activation gate:** replace `http://CHANGE_ME.invalid/internal/pattern-ingest` with a verified private OpenClaw Gateway URL, attach the environment token, test with a redacted synthetic event, and obtain an execution receipt before activation.
- **Fallback command:** the Pi installer automatically uses host n8n CLI or one uniquely detected running n8n container.

## 4. Pi/OpenClaw installation

- **Hardware:** Raspberry Pi 5, existing installation, 64-bit ARM expected.
- **OS:** preserve the existing OS and services; no reimage.
- **Services:** existing OpenClaw Gateway/node/skills/systemd recovery stack plus the new pattern-evolution skill. Preserve the existing Telegram inbound poller; never create a second poller.
- **Network:** preserve the existing LAN/Tailscale/Cloudflare arrangement. Do not add public port forwarding.
- **Provider secrets:** remain in Supabase. Do not copy provider/service-role keys to the Pi.
- **Paid fallback:** OFF.

### One-command physical continuation

Run as the normal Pi/OpenClaw service user. It downloads the installer file first; it does not pipe remote content directly into a shell.

```bash
set -euo pipefail
TMP=/tmp/install-openclaw-pattern-engine-v1.1.0.sh
curl -fsSLG \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  --data-urlencode 'ref=feat/supabase-emergency-bridge-20260819' \
  'https://api.github.com/repos/mnwersdfppa/no-cost-ai/contents/pi/install-openclaw-pattern-engine-v1.1.0.sh' \
| python3 -c 'import base64,json,sys; sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)["content"]))' \
> "$TMP"
chmod 700 "$TMP"
bash -n "$TMP"
bash "$TMP"
```

The installer performs these bounded actions:

1. fetches and semantically validates the versioned skill and inactive n8n workflow;
2. downloads the existing verified master-recovery installer from Supabase;
3. verifies its fixed SHA-256 `d8e4792e759d898a2a3c7434e973b82fdeddd10e291ac1d4973276ece7216419` before execution;
4. installs the OpenClaw skill under the existing workspace;
5. imports the n8n workflow through host CLI or one uniquely detected n8n container and leaves it inactive;
6. creates a local non-secret installation receipt.

## Completion evidence

Do not report physical completion until all are present:

- installer receipt;
- `agents.defaults.model` evidence;
- JWT refresh worker/timer evidence;
- recovery queue worker evidence;
- existing Telegram `/model default -s` → `/new` → `/status` evidence;
- real `openclaw message send` receipt;
- T4 correlation-ID round trip;
- rollback receipt;
- n8n import receipt with `active=false`.

Until then the canonical state remains `CLOUD_READY_PHYSICAL_PI_PENDING` even though the Supabase migration and Draft PR artifacts are complete.
