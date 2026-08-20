# OpenClaw Reliability Guardian — 2026-08-20

## Objective

Keep the existing Raspberry Pi 5 OpenClaw Telegram poller responsive when an upstream free model is overloaded, rate-limited, renamed, or temporarily unavailable.

## Safety invariants

- The existing OpenClaw Telegram consumer remains the only poller.
- Provider credentials remain in Supabase Edge secrets and are never committed or exported to Pi.
- Pi uses a scoped `pi-gateway-client` access token with refresh-token rotation.
- Paid API fallback remains disabled.
- OpenRouter direct fallback remains disabled until a distinct OpenRouter credential is validated.
- Tailscale credential `Tailscale-fff-api-key` is treated as a node enrollment auth key, not a tailnet management API token.
- No automatic main-branch merge or production deployment is performed by GitHub Actions.

## Supabase runtime design

```text
Telegram / OpenClaw on Pi 5
        ↓ scoped Pi JWT
pi-model-gateway-guardian
        ├─ current primary model
        ├─ distinct healthy fallback
        ├─ per-model circuit breaker
        └─ durable model_request_retry queue + safe acknowledgement
                         ↓
              model-retry-worker (pg_cron)
                         ↓
        telegram_result_delivery for existing Pi poller
```

## Current model evidence

A two-round live Responses benchmark found:

| Model | Result |
|---|---|
| `nemotron-3-ultra-free` | 2/2 successful; selected primary |
| `laguna-s-2.1-free` | 1/2 successful; degraded fallback |
| `deepseek-v4-flash-free` | 2/2 HTTP 429; quarantined |
| `mimo-v2.5-free` | 2/2 HTTP 429; quarantined |
| `big-pickle` | 2/2 HTTP 429; quarantined |

The circuit breaker must dynamically skip quarantined models. Static duplicate fallback chains are prohibited.

## Physical Pi gate

Cloud-side preparation does not prove that the Raspberry Pi's local `agents.defaults.model`, refresh timer, gateway process, Tailscale daemon, and Telegram round trip have been updated. Production completion requires the SHA-verified recovery installer and a redacted Pi receipt.

Installer SHA-256:

```text
4c21d9eab6fff335950f8a4c8c7a064a20b9aa00aead487b811cee779e8ae947
```

## Validation order

1. Supabase database and Edge secrets metadata.
2. Scoped Pi authentication and refresh exchange.
3. Guardian unauthorized rejection and primary response.
4. Forced total-route quarantine and durable queue acknowledgement.
5. Server retry worker claim, result persistence, and Pi delivery queue.
6. Physical Pi installer receipt.
7. Existing Telegram poller end-to-end test.

Do not mark the project complete before steps 6 and 7 pass.