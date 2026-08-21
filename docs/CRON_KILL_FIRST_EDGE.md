# OpenClaw Cron kill-first handoff

## Purpose

When the Raspberry Pi returns, stop the internal OpenClaw scheduler before model, authentication, or general recovery work. This prevents already-externalized macros from competing for CPU, memory, I/O, and model requests.

## Published artifact

- Edge: `pi-cron-kill-first-verified-20260822`
- Bytes: `4741`
- SHA-256: `77fc7ee1d4921f3c50ddf9da2f3c0684135ba859f1ad9ee2c810b2b0844aaa64`
- Upstream disable contract: immutable commit `ff3f0fad54c33498edb92dec985a8f1e043ef7f0`

## Order of operation

1. Verify the kill-first artifact.
2. Verify the v3 disable and rollback scripts.
3. Back up user crontab, user timers, OpenClaw Cron files, and SQLite when possible.
4. Apply `OPENCLAW_SKIP_CRON=1` to the Gateway user service.
5. Disable only externalized project crontab entries and timers.
6. Preserve recovery, session refresh, Telegram delivery, actuator, Gateway, and Tailscale control paths.
7. Install the fixed Supabase scheduler actuator for durable evidence and retry.
8. Write a local secret-free receipt.

## Rollback

`~/.openclaw/bin/openclaw-rollback-project-schedulers-v3`

The rollback removes the Gateway environment override and restores the most recent backed-up project crontab and timer state. Job definitions and SQLite are not deleted or rewritten.

## Boundaries

- no host reboot
- no arbitrary PID termination
- no queue-provided command execution
- no paid model fallback
- no second Telegram poller
- no secret values in receipts
