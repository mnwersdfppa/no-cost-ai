# Raspberry Pi activation — Supabase emergency bridge

## Preconditions

- Raspberry Pi has Python 3 and systemd user services.
- The Draft PR #5 checkout contains:
  - `pi/openclaw-emergency-bridge.py`
  - `scripts/install-supabase-emergency-bridge-on-pi.sh`
- `~/.openclaw/secrets/pi-work-queue.env` exists with mode `0600`.
- The file contains:
  - `SUPABASE_URL=https://dpllasnpfskyyyzebyal.supabase.co`
  - a current short-lived `PI_ACCESS_TOKEN` for the existing Supabase Auth user whose `app_metadata.role` is `pi-gateway-client`
- Do not place the service-role key, Supabase secret key, Vercel raw token, provider API keys, or OAuth tokens in this file.

## Install

From a checkout of Draft PR #5:

```bash
chmod +x scripts/install-supabase-emergency-bridge-on-pi.sh
scripts/install-supabase-emergency-bridge-on-pi.sh
```

The installer does not print the JWT or the selected Supabase publishable-key value. Timers remain disabled unless all of these authenticated tests pass:

1. emergency bridge status and safe-control verification;
2. paid OpenAI policy denial;
3. zero-cost-first route resolution without selecting OpenAI;
4. work-queue status;
5. canonical Supabase/Vercel configuration verification;
6. command-center status;
7. fixed-name credential-presence boundary verification.

It then enables:

- `openclaw-emergency-heartbeat.timer` every five minutes;
- `openclaw-credential-readiness.timer` once per day.

## Manual checks

```bash
~/.openclaw/bin/openclaw-emergency-bridge status
~/.openclaw/bin/openclaw-emergency-bridge heartbeat
~/.openclaw/bin/openclaw-emergency-bridge policy openai chat
~/.openclaw/bin/openclaw-emergency-bridge route model_chat 0
~/.openclaw/bin/openclaw-emergency-bridge route model_chat 4
~/.openclaw/bin/openclaw-emergency-bridge queue
~/.openclaw/bin/openclaw-emergency-bridge config
~/.openclaw/bin/openclaw-emergency-bridge command-status
~/.openclaw/bin/openclaw-emergency-bridge credentials
```

Expected paid-provider policy result:

```text
allowed=false
reason=paid_api_fallback_disabled
```

Expected routing behavior while only the local route is enabled:

```text
risk 0 → ollama.local or fail-closed when Pi health proves it unavailable
risk 4 → stop_no_eligible_route until the phone-backed route is separately verified and enabled
OpenAI paid route → never selected while paid_api_fallback=OFF
```

## Failure interpretation

- `AUTH_OR_ROLE_REJECTED=HTTP_401`: JWT expired or malformed.
- `AUTH_OR_ROLE_REJECTED=HTTP_403`: user lacks `pi-gateway-client` role or request was denied.
- `BRIDGE_RATE_LIMITED=HTTP_429`: the bounded hourly admission limit was reached.
- `BRIDGE_UNREACHABLE`: network or Edge Function unavailable.
- `STATUS_CONTROL_MISMATCH`: fail-closed controls changed; timers are not enabled.
- `CANONICAL_*`: canonical Supabase/Vercel routing changed or became incomplete.
- `COMMAND_CENTER_STATUS_MISSING`: command-center status contract failed.
- `*_SECRET_BOUNDARY_NOT_CONFIRMED`: a response no longer proves that server secrets and token derivatives were withheld; stop immediately.

The installer never auto-creates a new Pi user, never rotates credentials, never falls back to a service-role key, never starts a Telegram poller, and never invokes a paid provider.

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

Rollback does not delete the Pi Auth user, provider credentials, Supabase audit evidence, Telegram configuration, command-center records, or OpenClaw data.

## Completion evidence

Cloud preparation alone is not physical completion. Record all of the following before marking the Pi bridge active:

- one successful authenticated status response;
- one `HEARTBEAT=PASS` from the Pi;
- one paid OpenAI denial result;
- one zero-cost route result that does not select OpenAI;
- one queue-status response;
- one canonical-config response proving modern publishable selection, legacy anon fallback OFF, Vercel raw-token fallback OFF, and deployment OFF;
- one command-center status response;
- one credential-readiness response proving values, prefixes, hashes, and lengths were not returned;
- one non-secret row in `bridge_nodes` for `raspberry-pi5`;
- no second Telegram poller;
- no provider secret, Supabase server key, or Vercel raw token on the Pi;
- a separate existing-Telegram correlation-ID round trip before declaring the wider OpenClaw rollout complete.
