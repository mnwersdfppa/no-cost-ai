# Raspberry Pi activation — Supabase emergency bridge

## Preconditions

- Raspberry Pi has Python 3 and systemd user services.
- `~/.openclaw/secrets/pi-work-queue.env` exists with mode `0600`.
- The file contains:
  - `SUPABASE_URL=https://dpllasnpfskyyyzebyal.supabase.co`
  - a current short-lived `PI_ACCESS_TOKEN` for the existing Supabase Auth user whose `app_metadata.role` is `pi-gateway-client`
- Do not place the service-role key or provider API keys in this file.

## Install

From a checkout of Draft PR #5:

```bash
chmod +x scripts/install-supabase-emergency-bridge-on-pi.sh
scripts/install-supabase-emergency-bridge-on-pi.sh
```

The installer does not print the JWT. Before enabling timers, it must pass:

1. authenticated status request;
2. paid OpenAI policy denial;
3. queue status request.

It then enables:

- `openclaw-emergency-heartbeat.timer` every five minutes;
- `openclaw-credential-readiness.timer` once per day.

## Manual checks

```bash
~/.openclaw/bin/openclaw-emergency-bridge status
~/.openclaw/bin/openclaw-emergency-bridge heartbeat
~/.openclaw/bin/openclaw-emergency-bridge policy openai chat
~/.openclaw/bin/openclaw-emergency-bridge queue
~/.openclaw/bin/openclaw-emergency-bridge credentials
```

Expected policy result for `openai chat`:

```text
allowed=false
reason=paid_api_fallback_disabled
```

## Failure interpretation

- `AUTH_OR_ROLE_REJECTED=HTTP_401`: JWT expired or malformed.
- `AUTH_OR_ROLE_REJECTED=HTTP_403`: user lacks `pi-gateway-client` role or request was denied.
- `BRIDGE_UNREACHABLE`: network or Edge Function unavailable.
- `STATUS_CONTROL_MISMATCH`: fail-closed controls changed; timers are not enabled.
- `BRIDGE_SECRET_BOUNDARY_NOT_CONFIRMED`: response contract changed; stop immediately.

The installer never auto-creates a new Pi user, never rotates credentials, and never falls back to a service-role key.

## Rollback

```bash
systemctl --user disable --now \
  openclaw-emergency-heartbeat.timer \
  openclaw-credential-readiness.timer

rm -f \
  ~/.config/systemd/user/openclaw-emergency-heartbeat.service \
  ~/.config/systemd/user/openclaw-emergency-heartbeat.timer \
  ~/.config/systemd/user/openclaw-credential-readiness.service \
  ~/.config/systemd/user/openclaw-credential-readiness.timer \
  ~/.openclaw/bin/openclaw-emergency-bridge

systemctl --user daemon-reload
```

Rollback does not delete the Pi Auth user, provider credentials, Supabase audit evidence, Telegram configuration, or OpenClaw data.

## Completion evidence

Cloud preparation alone is not physical completion. Record all of the following before marking the Pi bridge active:

- one successful authenticated status response;
- one `HEARTBEAT=PASS` from the Pi;
- one paid OpenAI denial result;
- one queue-status response;
- one non-secret row in `bridge_nodes` for `raspberry-pi5`;
- no second Telegram poller;
- no provider secret or service-role key on the Pi.
