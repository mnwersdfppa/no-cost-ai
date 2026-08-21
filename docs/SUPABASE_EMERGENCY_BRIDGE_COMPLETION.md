# Supabase emergency bridge — completion boundary

## Cloud control plane: complete

The Supabase project `dpllasnpfskyyyzebyal` now contains a fail-closed emergency control plane for Raspberry Pi/OpenClaw.

Verified cloud invariants:

- bridge tables use RLS;
- `anon` and `authenticated` have no direct bridge-table privileges;
- service-role-only bridge functions use fixed `search_path` settings;
- unknown operations and unknown policies deny by default;
- paid API fallback is disabled;
- public shell execution is disabled;
- external and phone write actions are disabled;
- the existing Telegram poller remains the sole permitted owner;
- credential values, prefixes, hashes and lengths are not stored in the bridge registries;
- external connector OAuth sessions are not exported;
- credential source selection permits at most one selected alias per integration;
- selected Supabase and Vercel aliases each pass the canonical-selection self-test;
- invalid, blocked, quarantined, revoked or expired aliases cannot be selected;
- token usage has an idempotent execution-key index, RLS and service-role-only access;
- broad legacy database grants are inventoried in a non-destructive security backlog instead of being revoked automatically;
- five-minute bridge maintenance and daily security-backlog refresh jobs are active;
- `bridge_full_self_test()` passes.

JWT-protected Edge Functions:

- `emergency-bridge`
- `credential-readiness`
- `canonical-client-config`
- `pi-work-queue`

An unauthenticated request is rejected. The active bridge does not provide model inference or shell execution.

## Canonical credential sources

`bridge_credential_aliases` is the authoritative source-selection registry.
`bridge_credentials` stores integration-level readiness and runtime-presence metadata.
`bridge_selected_credentials` is the service-role-only read view.

### Supabase

- canonical project: `dpllasnpfskyyyzebyal`;
- new clients use the selected managed publishable-key source;
- legacy anon remains compatibility-only;
- server-side keys remain inside Supabase-managed Edge runtime;
- no service-role key is returned to the Pi.

### Vercel

- the connected Vercel session is the management source;
- the invalid raw Vault token is not selected and cannot be a fallback;
- deployment remains disabled until one target project is visible and explicitly validated.

## Existing application permissions

The bridge does not automatically revoke unrelated legacy `anon` or `authenticated` grants. Such changes can break existing applications. `bridge_security_backlog` records each candidate for separate review, including the Supabase Auth leaked-password-protection recommendation.

## Physical gate: pending

Cloud preparation does not prove that the Raspberry Pi currently possesses a valid short-lived JWT.

Physical completion requires:

1. place a current Pi user JWT in `~/.openclaw/secrets/pi-work-queue.env` with mode `0600`;
2. run `scripts/install-supabase-emergency-bridge-on-pi.sh`;
3. record authenticated status, heartbeat, paid-OpenAI denial and queue-status evidence;
4. record the Pi node in `bridge_nodes`;
5. separately complete the phone T3 verification;
6. separately complete the existing-Telegram T4 correlation-ID round trip.

Until those receipts exist, PR #5 remains Draft and Vercel deployment remains disabled.
