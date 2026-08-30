# Supabase-first emergency bridge

## Objective

Keep Raspberry Pi 5/OpenClaw usable during model, Telegram, desktop, phone, Vercel, or connector failures without copying server/provider secrets to the Pi or exposing shell execution publicly.

## Canonical control flow

```text
Raspberry Pi / OpenClaw
  -> short-lived Supabase Pi user JWT
  -> canonical-client-config
     -> current Supabase URL + modern default publishable key
     -> canonical Vercel connector/team metadata
     -> no server secret, raw Vercel token or legacy anon fallback
  -> emergency-bridge
     -> request admission + idempotency + rate limit
     -> permission matrix + fail-closed switches
     -> readiness / heartbeat / queue status
     -> redacted audit events
  -> pi-work-queue
     -> bounded queue operations only

Model routing remains separate:
  deterministic/cache -> local Ollama -> OpenRouter free-only
  -> phone Codex OAuth after T3 -> STOP
```

The emergency bridge does not perform model inference. It never returns service-role/secret keys, provider keys, OAuth tokens, Authorization headers, secret prefixes, hashes, or lengths.

## Canonical credential routing

### Supabase client

```text
Selected: SUPABASE_PUBLISHABLE_KEYS.default
Legacy anon automatic fallback: OFF
```

The selected modern publishable key is safe for a Pi client because all privileged data is protected by RLS and the Pi still needs its own signed-in user JWT. The function validates the current publishable key against the project Auth settings endpoint before returning it.

### Supabase server

```text
Selected in Edge runtime: SUPABASE_SECRET_KEYS.default
Compatibility only: SUPABASE_SERVICE_ROLE_KEY
Returned to Pi/client: NEVER
```

The modern named secret key is preferred inside the hosted Edge runtime. Legacy service-role compatibility remains internal only while older functions are migrated.

### Vercel management

```text
Selected: connected Vercel connector session
Team: team_sa2sEffAlVXK6b9lsweDm6QL
Raw token fallback: OFF
Deployment: OFF until a project is visible and explicitly selected
```

The invalid Vault token is quarantined. The untested webhook candidate is retained but unselected until signature, origin, positive and negative tests pass.

## Applied components

| Component | Purpose | Default |
|---|---|---|
| `bridge_credentials` | Credential reference, scope and validation status only | no values |
| `bridge_credential_aliases` | One selected alias per integration; invalid candidates quarantined | active |
| `bridge_controls` | Fail-closed feature switches | writes/paid paths off |
| `bridge_permission_policies` | Operation-level allow/deny, approval and limits | read-only Supabase actions on |
| `bridge_route_registry` | Non-secret route metadata | canonical/status/queue on |
| `bridge_nodes` | Pi/phone/desktop liveness | heartbeat only |
| `bridge_events` | Recursively redacted audit ledger | enabled |
| `bridge_request_ledger` | Idempotency and hourly request limits | enabled |
| `bridge_deployment_receipts` | Regression/self-test evidence | enabled |
| `canonical-client-config` | Current modern client configuration | active, JWT required |
| `emergency-bridge` | Status/policy/heartbeat endpoint | active, JWT required |
| `credential-readiness` | Runtime presence booleans only | active, JWT required |
| `maintain-emergency-bridge` | Stale-node and ledger maintenance | every 5 minutes |
| `canonical-config-agent.py` | Pi fetch/validation/atomic cache | prepared |
| `openclaw-canonical-config.timer` | Refresh canonical config | every 6 hours after Pi install |

All bridge tables use RLS, explicit deny policies for `anon` and `authenticated`, revoked direct grants, and service-role-only Edge Function access.

## Safe defaults

```text
emergency_bridge=ON
supabase_control_plane=ON
supabase_modern_publishable_key=ON
supabase_legacy_anon_fallback=OFF
vercel_connector_management=ON
vercel_raw_token_fallback=OFF
vercel_deployments=OFF
paid_api_fallback=OFF
external_write_actions=OFF
phone_write_actions=OFF
public_shell_execution=OFF
telegram_single_poller_enforced=ON
maton_readonly=OFF
make_webhook=OFF
n8n_queue_worker=OFF
phone_codex_route=OFF
openrouter_free_route=OFF
local_ollama_route=ON
```

## Pi actions

The Pi JWT must belong to an Auth user whose `app_metadata.role` is `pi-gateway-client`.

Supported emergency actions:

- `status`: controls, credential states, routes, nodes and queue counts
- `heartbeat`: bounded, recursively redacted node liveness update
- `policy_check`: fail-closed integration/operation decision
- `queue_status`: bounded work-queue status

Unsupported actions and unknown permission policies are denied.

## Pi canonical configuration agent

Files:

```text
pi/canonical-config-agent.py
pi/install-canonical-config-agent.sh
```

The installer creates a protected session file and a hardened systemd user service/timer. The agent:

1. calls `canonical-client-config` with the Pi user JWT;
2. refreshes an expired session only when a Pi refresh token and an already validated cached publishable key exist;
3. validates project ref, URL, modern key type, Vercel team and all fail-closed policy invariants;
4. atomically replaces the cached files only after every check passes;
5. writes mode-0600 files and never prints keys or tokens.

Outputs after successful physical installation:

```text
~/.openclaw/runtime/canonical-client.json
~/.openclaw/runtime/supabase-client.env
```

The timer refreshes every six hours and persists across reboot. A failed refresh preserves the previous validated cache.

## Credential source rules

A credential may exist in isolated runtimes. Edge absence must not overwrite Pi-local, OAuth-device, n8n, Vault, or external-connector validation.

- `platform_managed`: Supabase-provided modern key dictionaries
- `supabase_edge_env`: custom Edge Function runtime variables
- `supabase_vault`: database Vault reference; never returned to Pi
- `pi_local_secret`: `~/.openclaw/secrets/*.env`, mode `0600`
- `oauth_device`: token remains on the authenticated phone/device
- `n8n_credential`: stored only inside n8n credential storage
- `connector_external`: available to a connected ChatGPT connector only

`credential-readiness` records only boolean Edge-runtime presence. It does not return values, prefixes, hashes, or lengths and preserves validated states from other runtimes.

## Integration sequence by lowest difficulty

1. Canonical Supabase client configuration.
2. Supabase readiness/status/heartbeat/policy endpoint.
3. Existing Supabase work queue and lease recovery.
4. Pi six-hour canonical-config refresh timer.
5. Local Ollama health route.
6. Maton OAuth, read-only discovery tools only.
7. n8n inactive workflow import and local credentials.
8. Make authenticated/idempotent queue pulse.
9. Phone Codex OAuth after physical T3 and rollback evidence.
10. Vercel deployment only after project visibility and explicit selection.
11. Paid OpenAI only by explicit operator approval; never automatic fallback.

## Conflict prevention

- OpenClaw remains the sole Telegram poller.
- Supabase endpoints do not execute shell commands or model inference.
- Pi receives only a publishable key plus its user session, never a server secret.
- n8n/Make may enqueue bounded work but do not own Telegram polling.
- Maton write tools remain excluded until a specific action is reviewed.
- Vercel deployment remains off while no canonical project is visible.
- Invalid Vault candidates cannot become fallbacks.
- Credential values never move through GitHub, Linear, Telegram, receipts, or queue payloads.

## Smoke tests

```bash
chmod +x scripts/test-supabase-emergency-bridge.sh
scripts/test-supabase-emergency-bridge.sh
```

The script reads the Pi JWT locally and does not print it. It confirms:

- canonical modern publishable-key configuration;
- legacy anon and raw Vercel token fallbacks are off;
- Vercel deployment is off;
- emergency status access;
- paid OpenAI policy denial;
- queue status.

## Non-destructive rollback

Run `supabase/rollback/20260819080000_emergency_bridge_disable.sql` and deploy 410 fail-closed stubs for the three Edge Functions. Rollback preserves schema and audit evidence and does not change provider credentials or the Pi Auth user.

## Separate security backlog

The emergency bridge tables are fail-closed. Supabase advisors also report older unrelated public-schema objects that remain visible through GraphQL to `anon` or all signed-in users. They are not mass-revoked here because their intended consumers and compatibility are not yet mapped. Review them table-by-table in a separate migration.

Supabase Auth leaked-password protection is also disabled. Enable it in the Supabase Auth dashboard after confirming the intended sign-in policy; no connected management action currently exposes that setting.

## Completion boundary

Cloud control-plane preparation and deterministic self-test are complete. Full operational completion still requires:

1. a current Pi user access token and preferably refresh token stored locally;
2. physical installation of the Pi agent/timer;
3. one authenticated `canonical-client-config` call from the Pi;
4. one Pi heartbeat and full smoke test;
5. a visible, explicitly selected Vercel project before deployment is enabled;
6. separate T3 phone bridge evidence and T4 existing-Telegram correlation round trip.
