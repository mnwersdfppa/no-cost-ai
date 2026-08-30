# OpenClaw Pi Recovery Worker — Cloud Activation Receipt

Date: 2026-08-20  
Status: `CLOUD_READY_PHYSICAL_PI_PENDING`  
Supabase project: `dpllasnpfskyyyzebyal`

## Activated cloud path

```text
Raspberry Pi OpenClaw
  -> scoped pi-gateway-client JWT
  -> Supabase pi-model-gateway-guardian
  -> OpenCode Zen supported model
  -> bounded distinct fallback
  -> durable Supabase queue + Telegram-safe acknowledgement
```

Canonical gateway:

```text
https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-model-gateway-guardian/v1
```

Primary model:

```text
supabase-opencode/nemotron-3-ultra-free
```

Current successful distinct fallback:

```text
supabase-opencode/laguna-s-2.1-free
```

Local independent fallback after authenticated Pi health verification:

```text
ollama/qwen2.5:3b
```

## Queue contract v2

The Pi worker can claim only these task types:

1. `pi_supabase_auth_model_recovery`
2. `worker_liveness_guardian`
3. `telegram_model_failover_repair`

Queue payloads are data only. The worker does not evaluate payload commands, shell fragments, URLs, or executable paths. Each task type maps to a fixed handler compiled into the worker.

## Failure handling

- Maximum immediate provider attempts: 2
- HTTP 429: model circuit breaker quarantine
- HTTP 5xx: short model quarantine
- Timeout: short model quarantine
- Total provider failure: durable queue entry
- Telegram-visible result: safe acknowledgement instead of the raw provider overload message
- Paid provider fallback: disabled
- Second Telegram poller: prohibited

## Credentials

- `Opencode-api-key` remains in Supabase Edge secrets.
- The raw OpenCode credential is never exported to the Pi.
- `Tailscale-fff-api-key` is classified as a node enrollment auth key, not a tailnet management API token.
- Tailscale key delivery is authenticated, one-time, and deleted locally after successful enrollment.
- Pi receives only a scoped Supabase user session.

## Pi worker files

- `pi/openclaw-recovery-worker.py`: bounded worker core
- `pi/openclaw-recovery-worker-v2.py`: canonical launcher and self-test
- `pi/install-openclaw-recovery-worker-v2.sh`: user systemd oneshot/timer installer
- `pi/recover-openclaw-telegram-models.sh`: fixed local Ollama fallback handler
- `.github/workflows/openclaw-recovery-worker-validate.yml`: validation-only CI

## Verified Supabase installer

```text
https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-recovery-worker-installer-verified
```

The verified endpoint checks the DB-pinned SHA-256 of the generated installer before returning it. The generated installer embeds and verifies the pinned GitHub source files, then runs the previously verified Pi session/model recovery installer before enabling the bounded worker timer.

## Remaining physical gate

The cloud path is ready. Completion still requires executing the verified installer on the physical Raspberry Pi and retaining its redacted receipt.

```bash
curl -fsS -o /tmp/openclaw-worker-recovery.sh \
  https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-recovery-worker-installer-verified \
&& bash /tmp/openclaw-worker-recovery.sh
```

After execution, verify:

```bash
systemctl --user status openclaw-pi-recovery-worker.timer --no-pager
openclaw gateway status
cat ~/.openclaw/runtime/pi-recovery-worker-bootstrap-receipt.json
```

Telegram session pin reset, when required:

```text
/model default -s
```

No production merge is authorized by this receipt. Draft PR review and physical Pi evidence remain required.
