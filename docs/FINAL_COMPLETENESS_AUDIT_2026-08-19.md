# Final completeness audit — Supabase-first emergency bridge

Date: 2026-08-19

## Overall result

`PARTIAL_PHYSICAL_GATE`

The cloud control plane, safe credential routing, non-secret audit layer, zero-cost-first route decision, rollback package and Raspberry Pi installer are prepared and structurally verified. The overall system is not marked complete until a real Raspberry Pi uses its current short-lived JWT for an authenticated status/config/heartbeat round trip.

## Verified in Supabase

- Project reference: `dpllasnpfskyyyzebyal`.
- `emergency-bridge`, `credential-readiness` and `canonical-client-config` are JWT-protected.
- Only an Auth user with `app_metadata.role=pi-gateway-client` is accepted by the emergency bridge.
- Bridge tables have RLS enabled and expose no direct `anon` or ordinary `authenticated` grants.
- Security-definer functions revoke execution from `anon` and ordinary `authenticated` roles.
- Request admission provides operation allowlisting, hourly limits and execution-key idempotency.
- Unknown operations and missing policies fail closed.
- Credential readiness returns only fixed integration names with present/missing booleans; values, prefixes, hashes and lengths are not returned.
- Credential and connector records store source/status metadata only. Credential export is disabled for every registered capability.
- `paid_api_fallback=OFF`.
- `external_write_actions=OFF`.
- `phone_write_actions=OFF`.
- `public_shell_execution=OFF`.
- `telegram_single_poller_enforced=ON`.
- Existing token-gateway usage has RLS, service-role-only access, execution-key uniqueness and usage indexes.
- Five-minute bridge maintenance and daily non-destructive security-backlog refresh are scheduled.
- Legacy application grants and Auth warnings are inventoried but are not destructively changed by this rollout.

## Canonical credential routing

### Supabase

- Canonical project: `dpllasnpfskyyyzebyal`.
- New client configuration selects the managed modern publishable key named `default`.
- Server-side Edge Functions select the managed secret key named `default` when available.
- Legacy anon/service-role credentials remain compatibility-only and are not automatic new-client fallbacks.
- The previously invalid Supabase Vault candidate remains quarantined.
- Raspberry Pi receives only the project URL and publishable client configuration; no server credential is returned.

### Vercel

- Canonical management path is the connected Vercel connector session.
- Canonical team remains `team_sa2sEffAlVXK6b9lsweDm6QL` / `mnwersdfppap-5454s-projects`.
- Raw-token fallback remains disabled because the stored candidate previously failed validation.
- Deployment remains disabled until a project is visible to the canonical connector session and explicitly selected.
- No Vercel server token is copied into Supabase client configuration or Raspberry Pi files.

## Zero-cost-first route contract

The route registry and resolver enforce this order without calling a provider during resolution:

1. local Ollama when the Pi heartbeat reports a usable local route;
2. OpenRouter free-only only after its credential and free-only behavior are validated;
3. phone Codex/ChatGPT subscription OAuth only after physical T3 verification and explicit enablement;
4. STOP when no eligible route exists.

The paid OpenAI API route is disabled and tied to the separate `paid_api_fallback` kill switch. Route resolution cannot select it while that switch is off.

## External connector boundaries

Registered without credential export:

- GitHub and Linear: connected and used for Draft PR/rollout evidence.
- Gmail: connected read/search boundary; secret extraction and automatic sending excluded.
- Vercel: connected management boundary; deployment disabled pending project visibility.
- Notion, Superhuman Mail, ButlerBrain, Insurance GPT and Payload Completeness Checker: registered disabled until a concrete scope and connection test are approved.
- OpenAI Developers, OpenAI Ads Conversions and Codex Security: recorded as Codex-oriented skills, not runtime credentials.
- NVIDIA: no validated credential or emergency route in this runtime.

## Raspberry Pi package

Prepared artifacts include:

- a fail-closed Pi emergency client and installer;
- authenticated status, heartbeat, queue, policy and credential-readiness checks;
- hardened systemd user services and timers;
- a separate canonical-client configuration agent;
- non-secret output and atomic configuration writes;
- rollback commands that disable timers and remove only installed bridge artifacts;
- no service-role key or provider API key requirement on the Pi.

## Verification completed without physical access

- Supabase structural self-test: PASS.
- Zero-cost route contract: PASS.
- Paid OpenAI denial: PASS.
- Unknown-policy fail-closed behavior: PASS.
- Credential-readiness admission and duplicate execution-key behavior: PASS.
- Unauthenticated Edge invocation rejection: PASS.
- Local repository syntax, JSON, secret-pattern, execution-primitive and non-destructive rollback checks: PASS.

## Remaining hard gates

### P0 — real Raspberry Pi authentication

Required evidence:

1. current short-lived `PI_ACCESS_TOKEN` in the Pi-local `0600` environment file;
2. authenticated `canonical-client-config` call;
3. authenticated `emergency-bridge status` call;
4. `HEARTBEAT=PASS` recorded in `bridge_nodes`;
5. paid OpenAI policy denial returned to the Pi;
6. queue-status response;
7. no server secret or provider key on the Pi.

### P1 — phone model route

T3 requires the real Pi/phone bridge, phone OAuth status, live backend response and rollback evidence.

### P2 — Telegram round trip

T4 requires one correlation-ID round trip through the existing OpenClaw Telegram bot. A second poller or competing webhook owner is forbidden.

### P3 — Vercel

A connected project must become visible under the canonical Vercel team before Git linkage or preview deployment can be verified. Production deployment remains blocked.

## Completion rule

Cloud preparation, a passing CI job, an accepted queue item or an HTTP 200 response is not the overall completion signal. Overall status becomes `COMPLETE` only after P0, T3 and T4 evidence exists and rollback has been verified.
