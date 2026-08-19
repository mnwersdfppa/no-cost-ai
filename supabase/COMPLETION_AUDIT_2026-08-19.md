# Supabase-first emergency bridge completion audit

Audit date: 2026-08-19

## Canonical identities

- Supabase project: `dpllasnpfskyyyzebyal`
- Supabase URL: `https://dpllasnpfskyyyzebyal.supabase.co`
- Canonical client credential: managed modern `default` publishable key
- Legacy anon key: compatibility only; not selected for new Pi/client configuration
- Canonical server credential: managed Edge runtime secret; never returned to Pi
- Vercel management identity: connected Vercel connector session
- Vercel team: `team_sa2sEffAlVXK6b9lsweDm6QL` / `mnwersdfppap-5454s-projects`
- Invalid raw Supabase and Vercel Vault candidates: quarantined; automatic fallback disabled

No credential value, prefix, hash, length, Authorization header, OAuth token, or service-role key is stored in this report.

## Live Supabase control plane

Active JWT-protected functions:

- `canonical-client-config`
- `credential-readiness`
- `emergency-bridge`
- `pi-work-queue`
- `token-gateway`

The canonical configuration function returns only the project URL, the selected publishable client key, public routing metadata, and safety policy. It never returns a server secret.

## Database hardening

The completion review verifies:

- 9 required bridge tables exist
- Row Level Security is enabled on all 9 bridge tables
- all 9 tables have explicit restrictive deny policies for `anon` and `authenticated`
- direct `anon` and `authenticated` table grants are zero
- unsafe execute grants on bridge security-definer functions are zero
- canonical credential switches are fail-closed
- required canonical routes and operation policies are registered
- emergency maintenance cron is active
- token usage has RLS, unique `execution_key`, operational indexes, a daily usage view, and a fail-closed provider policy gate

`bridge_self_test()` v2 recorded `pass`. It inspected no secret value and called no paid provider.

## Negative authentication test

The following functions were invoked without an Authorization header:

1. `emergency-bridge`
2. `credential-readiness`
3. `canonical-client-config`

All three rejected the requests with HTTP 401. A non-secret deployment receipt records the result.

## Safe defaults

- paid API fallback: OFF
- external write actions: OFF
- phone write actions: OFF
- public shell execution: OFF
- legacy Supabase anon fallback for new clients: OFF
- Vercel raw-token fallback: OFF
- existing Telegram single-poller enforcement: ON
- local Ollama attempt: allowed, fail-closed
- Maton, Make, n8n, Vercel deployment, and phone-Codex routes: disabled until their individual gates pass

## Source validation

The earlier invalid bare PL/pgSQL trigger loop was replaced by an idempotent `DO` block. The Supabase emergency-bridge workflow was replayed locally and the current GitHub Actions run passed after the fix.

## Remaining evidence gate

Source, database, Edge Function, permission, negative-authentication, and rollback preparation are complete.

The only unresolved bridge acceptance gate is a real authenticated Pi invocation using a current short-lived JWT whose user metadata contains `role=pi-gateway-client`:

1. call `canonical-client-config`
2. call `credential-readiness`
3. call `emergency-bridge` with `status`
4. send one redacted `heartbeat`
5. record the correlation IDs and receipts

`pi-auth-bootstrap` remains deliberately disabled. No bypass JWT was minted during this completion review.

## Deliberately not performed

- no secret output or copying
- no credential rotation or deletion
- no paid model call
- no Vercel deployment
- no pull-request merge
- no second Telegram poller
- no public shell endpoint
