# Supabase emergency bridge deployment manifest

Project: `dpllasnpfskyyyzebyal`

## Canonical key policy

- Client configuration resolves `SUPABASE_PUBLISHABLE_KEYS["default"]`.
- Server/Edge code resolves `SUPABASE_SECRET_KEYS["default"]` first.
- `SUPABASE_SERVICE_ROLE_KEY` exists only as an incremental compatibility fallback inside trusted Edge runtime.
- No server key, Vercel token, provider key, OAuth token, prefix, hash, or length is returned to the Raspberry Pi.
- Legacy anon fallback is disabled for newly generated client configuration.
- Connected Vercel connector session is the canonical management identity; raw-token fallback is disabled.

## Deployed functions

| Function | JWT | Purpose |
|---|---:|---|
| `emergency-bridge` | required | readiness, heartbeat, policy and queue status |
| `credential-readiness` | required | boolean runtime-presence inventory only |
| `canonical-client-config` | required | canonical public client configuration for the Pi |
| `pi-work-queue` | required | bounded work claim/complete/fail lane |
| `token-gateway` | required | guarded model/provider gateway; paid fallback remains disabled by control policy |

## Deployment/runtime source

The live `emergency-bridge`, `credential-readiness`, and `canonical-client-config` deployments use modern-first managed-key resolution. `canonical-client-config/index.v2.ts` records the current canonical response contract. The shared resolver is in `_shared/managed-keys.ts`.

## Required physical evidence

1. A current short-lived JWT belonging to a Supabase user whose `app_metadata.role` is `pi-gateway-client`.
2. Successful Pi call to `canonical-client-config`.
3. Atomic creation of `~/.openclaw/secrets/supabase-canonical-client.env` with mode `0600`.
4. Successful heartbeat and policy-check calls through `emergency-bridge`.
5. No server secret or raw Vercel token in the response or logs.

Unauthenticated requests are expected to return HTTP 401. Physical Pi JWT evidence is intentionally not fabricated in CI.
