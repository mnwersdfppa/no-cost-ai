# Supabase-first emergency bridge

## Objective

Keep Raspberry Pi 5/OpenClaw usable during model, Telegram, desktop, phone, or connector failures without copying provider secrets to the Pi or exposing shell execution publicly.

## Control flow

```text
Raspberry Pi / OpenClaw
  -> short-lived Supabase Pi JWT
  -> emergency-bridge Edge Function
     -> request admission + idempotency + rate limit
     -> permission matrix + fail-closed switches
     -> readiness / heartbeat / queue status
     -> redacted audit events

Model routing remains separate:
  rule/cache -> local Ollama -> OpenRouter free-only -> phone Codex OAuth -> STOP
```

The emergency bridge does not perform model inference and never returns service-role keys, provider keys, OAuth tokens, Authorization headers, prefixes, hashes, or secret lengths.

## Applied components

| Component | Purpose | Default |
|---|---|---|
| `bridge_credentials` | Credential reference, scope and validation status only | no values |
| `bridge_controls` | Fail-closed feature switches | writes/paid paths off |
| `bridge_permission_policies` | Operation-level allow/deny, approval and limits | read-only Supabase actions on |
| `bridge_route_registry` | Non-secret route metadata | Supabase status/queue on |
| `bridge_nodes` | Pi/phone/desktop liveness | heartbeat only |
| `bridge_events` | Recursively redacted audit ledger | enabled |
| `bridge_request_ledger` | Idempotency and hourly request limits | enabled |
| `bridge_deployment_receipts` | Regression/self-test evidence | enabled |
| `emergency-bridge` | JWT-protected status/policy/heartbeat endpoint | active |
| `credential-readiness` | Runtime presence booleans only | active |
| `maintain-emergency-bridge` | Mark stale nodes offline and clean old ledgers | every 5 minutes |

## Safe defaults

```text
emergency_bridge=ON
supabase_control_plane=ON
paid_api_fallback=OFF
external_write_actions=OFF
phone_write_actions=OFF
public_shell_execution=OFF
telegram_single_poller_enforced=ON
maton_readonly=OFF
make_webhook=OFF
n8n_queue_worker=OFF
vercel_deployments=OFF
phone_codex_route=OFF
openrouter_free_route=OFF
local_ollama_route=ON
```

## Pi actions

The Pi JWT must belong to an Auth user whose `app_metadata.role` is `pi-gateway-client`.

Supported actions:

- `status`: controls, credential statuses, route status, node status and queue counts
- `heartbeat`: bounded redacted node liveness update
- `policy_check`: fail-closed integration/operation decision
- `queue_status`: bounded work-queue status

Unsupported actions return an error. Unknown permission policies are denied.

## Credential source rules

A credential may exist in several isolated runtimes. Edge absence must not overwrite a Pi-local, OAuth-device, n8n, Vault, or external-connector record.

- `supabase_edge_env`: only Edge Function runtime variables
- `supabase_vault`: database Vault reference; not returned to Pi
- `pi_local_secret`: `~/.openclaw/secrets/*.env`, mode `0600`
- `oauth_device`: token remains on the authenticated device
- `n8n_credential`: stored only inside n8n credential storage
- `connector_external`: available to a connected ChatGPT connector only
- `platform_managed`: Supabase-provided runtime values

`credential-readiness` records only `true/false` for Edge runtime presence. It preserves validated states from other runtimes.

## Integration sequence by lowest difficulty

1. Supabase readiness/status/heartbeat/policy endpoint.
2. Existing Supabase work queue and lease recovery.
3. Local Ollama health route.
4. Maton OAuth, read-only discovery tools only.
5. n8n inactive workflow import and local credentials.
6. Make authenticated/idempotent queue pulse.
7. Phone Codex OAuth after physical T3 and rollback evidence.
8. Vercel only after replacing the invalid credential and proving project visibility.
9. Paid OpenAI only by explicit operator approval; never automatic fallback.

## Conflict prevention

- OpenClaw remains the sole Telegram poller.
- Supabase does not execute shell commands.
- n8n/Make may enqueue bounded work but do not own Telegram polling.
- Maton write tools remain excluded until a specific action is reviewed.
- Vercel deployment remains off while the credential is invalid.
- Credential values never move through GitHub, Linear, Telegram, receipts, or request payloads.

## Smoke test

```bash
chmod +x scripts/test-supabase-emergency-bridge.sh
scripts/test-supabase-emergency-bridge.sh
```

The script reads the Pi JWT locally, never prints it, confirms status access, confirms the paid OpenAI policy is denied, and checks queue status.

## Non-destructive rollback

Run `supabase/rollback/20260819080000_emergency_bridge_disable.sql` and deploy 410 fail-closed stubs for both Edge Functions. The rollback preserves schema and audit evidence and does not change provider credentials or the Pi Auth user.

## Completion boundary

The cloud control plane can be fully applied and self-tested independently. Physical completion still requires:

1. current short-lived JWT installed on the Pi;
2. one Pi heartbeat through `emergency-bridge`;
3. one smoke test from the Pi;
4. separate T3 phone bridge evidence and T4 existing-Telegram correlation round trip.
