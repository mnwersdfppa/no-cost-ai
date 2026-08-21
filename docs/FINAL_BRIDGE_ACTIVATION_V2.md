# Final Supabase-first OpenClaw bridge activation

## Prepared cloud state

- Supabase project: `dpllasnpfskyyyzebyal`
- Client credential source: `SUPABASE_PUBLISHABLE_KEYS.default`
- Server credential target: `SUPABASE_SECRET_KEYS.default`
- Legacy anon automatic fallback: disabled
- Raw Vercel token fallback: disabled
- Vercel deployment: disabled until a project is visible and explicitly selected
- Paid OpenAI API fallback: disabled
- Existing Telegram single-poller invariant: enabled
- Public shell and phone-write actions: disabled

## One-time Pi activation

A current short-lived Pi user JWT is required. Do not copy a service-role key or provider API key to the Pi.

```bash
cd /path/to/no-cost-ai
chmod +x \
  pi/openclaw-bridge-agent.py \
  pi/install-openclaw-bridge-agent.sh \
  pi/uninstall-openclaw-bridge-agent.sh

pi/install-openclaw-bridge-agent.sh
```

If the session file does not yet exist, the installer creates:

```text
~/.openclaw/secrets/pi-work-queue.env
```

Insert only:

```text
PI_ACCESS_TOKEN=<current short-lived Pi user JWT>
PI_REFRESH_TOKEN=<optional Pi user refresh token>
```

Then rerun the installer. The token values are never printed.

## Verification chain

Before enabling any timer, the installer must pass all of the following:

1. canonical client configuration;
2. Pi heartbeat and local capability probe;
3. fixed-name credential-presence scan with no values or secret derivatives;
4. command-center status read;
5. paid OpenAI policy denial;
6. work-queue status read;
7. zero-cost-first route decision;
8. complete bridge status;
9. fresh `modern_secret_default` runtime receipts from:
   - `canonical-client-config`
   - `credential-readiness`
   - `emergency-bridge`
   - `command-center`

If any step fails, no timer is enabled.

## Timers after verification

- heartbeat: every 5 minutes
- canonical client configuration: every 6 hours
- command-center status: every 30 minutes
- credential readiness: every 24 hours

## Evidence

The Pi writes a non-secret receipt to:

```text
~/.openclaw/runtime/bridge-verification-receipt.json
```

Physical completion still additionally requires:

- phone Codex OAuth T3 round trip;
- existing Telegram bot T4 correlation-ID round trip;
- no second Telegram poller;
- no service-role or provider secret copied to the Pi.

## Rollback

```bash
pi/uninstall-openclaw-bridge-agent.sh
```

Rollback removes only the new user-level timers and agent binary. It retains the Pi user, session file, OpenClaw data, Telegram configuration, Supabase evidence, and provider credentials.
