# Disabled integration absorption packets

These files prepare Maton, Make and n8n without activating credentials or side effects.

## Current state

| Integration | Prepared | Active | Reason |
|---|---:|---:|---|
| Maton MCP read-only discovery | yes | no | `MATON_API_KEY` must be visible to the Pi Gateway runtime, not merely stored in Supabase Edge Function secrets |
| Make signed webhook | yes | no | webhook URL/signing secret and negative tests are still required |
| n8n bounded queue | yes | no | credentials must be created in n8n and the workflow must pass dry-run tests before activation |

## Activation order

1. Confirm runtime-local secret presence using present/missing output only.
2. Activate Maton discovery tools only: `whoami`, app/action search, schema inspection and connection listing.
3. Keep Maton `run_action`, generic `api`, connection creation/deletion excluded.
4. Test the Make webhook signature, invalid-signature rejection and idempotency.
5. Import the n8n packet as inactive, bind credentials internally, then test queue-only behavior.
6. Do not connect phone control, Telegram polling, payment, deletion, merge, deploy, reboot or credential mutation to these webhooks.

## Why Supabase secrets are not enough by themselves

Supabase Edge Function secrets are process-local to hosted Edge Functions. The Raspberry Pi OpenClaw Gateway cannot read them automatically. A key must either be installed through a local SecretRef on the Pi or remain server-side behind a narrowly scoped authenticated proxy. Never copy it into GitHub, Linear, Telegram, command arguments or logs.

## Completion evidence

Activation requires a receipt containing only:

- proposal ID and immutable commit SHA
- tool names exposed
- valid/invalid signature test results
- duplicate execution-key result
- SecretRef names and present/missing state
- confirmation that the existing Telegram bot remains the sole poller

No key material, key prefix, token hash, authorization header or OAuth code belongs in the receipt.
