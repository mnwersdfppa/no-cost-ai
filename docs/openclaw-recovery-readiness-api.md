# OpenClaw recovery readiness API

## Endpoint

```text
GET https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/openclaw-recovery-readiness
```

The endpoint requires a current Supabase user JWT whose `app_metadata.role` is exactly `pi-gateway-client`.

```http
Authorization: Bearer <short-lived Pi access token>
```

No Supabase server key, OpenCode key, Tailscale auth key, Telegram bot token, refresh token, or Authorization header is returned.

## State contract

```text
CLOUD_REPAIR_INCOMPLETE
CLOUD_READY_PHYSICAL_PI_PENDING
COMPLETE_VERIFIED
```

`CLOUD_READY_PHYSICAL_PI_PENDING` means the cloud Guardian, bootstrap, recovery queue contract and verified Pi installer are ready, but the physical Raspberry Pi has not yet supplied its installation and Telegram round-trip receipt.

## Included non-secret sections

- canonical model route
- per-model circuit-breaker status
- queue counts
- completion gates
- safety flags

## Safety invariants

```text
paid_api_fallback=false
single_telegram_poller=true
payload_shell_execution=false
second_telegram_poller=false
provider_secret_returned=false
secret_values_included=false
```

## Intended callers

1. Raspberry Pi recovery worker after refreshing its scoped session.
2. Read-only status UI after authenticated server mediation.
3. Verification tooling that does not perform Telegram polling.

Vercel must not become a model worker or Telegram poller. A future Vercel status page may display this response only through an authenticated server route and must not receive provider credentials.

## Completion boundary

This endpoint is status evidence, not physical completion. The PR remains Draft until:

1. the verified worker installer runs on Raspberry Pi;
2. the Pi recovery receipt is returned;
3. the existing Telegram bot completes `/model default -s`, `/new`, and a correlation-ID round trip;
4. Tailscale enrollment is verified separately when used.
