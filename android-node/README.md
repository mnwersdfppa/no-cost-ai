# OpenClaw mobile runtime bridge for Raspberry Pi 5

This package turns a USB-connected mini Android phone into a bounded OpenClaw companion and, when the official Codex CLI works on the phone but not on the Pi, into a subscription-backed text backend. **Root, jailbreak, Magisk, bootloader changes and custom ROMs are neither required nor used.**

## Architecture

```text
Telegram (one existing poller)
  -> Raspberry Pi 5 OpenClaw Gateway
     -> official OpenClaw Android/iOS node
     -> USB ADB MCP status/inspection fallback
     -> phone-codex-cli/gpt-5.6-sol
          -> USB-forwarded forced-command SSH
          -> verified official Codex CLI in Termux
```

The phone never becomes a second Telegram poller. The Pi remains the single Gateway and routing owner.

## S-rank absorption

- `openclaw/openclaw`: official Android/iOS node and setup-code pairing.
- `openai/codex`: official phone-side Codex CLI and ChatGPT subscription login.
- `Genymobile/scrcpy` and Android platform-tools: no-root USB inspection fallback.
- `termux/termux-app`, Termux:API and Termux:Boot: constrained phone runtime.
- `modelcontextprotocol/typescript-sdk`: local stdio MCP tools with allowlists.
- `tailscale/tailscale`: optional private remote transport.
- `maton-ai/agent-toolkit`: optional remote OAuth MCP, read-only tools first.

`RikkaApps/Shizuku` remains conditional for a proven capability gap. Third-party root tools and unofficial Codex installers are excluded.

## Security boundaries

- No arbitrary `adb shell` tool.
- Production phone writes are limited to launching OpenClaw or Termux and HOME/BACK/WAKEUP/SLEEP.
- Generic URLs, taps, swipes and free-form text are not registered with OpenClaw.
- Calls, SMS, purchases, app install/uninstall, account changes and security-setting changes are not implemented.
- The Pi key and the Android SSH host key must each be exactly one ED25519 record.
- First host-key pinning verifies the operator-recorded SHA256 fingerprint and atomically writes only that record.
- Official Codex `0.146.0` registry metadata, tarball, integrity and shasum are pinned before installation.
- API-key and proxy environment variables are removed from phone-backed inference.
- Promotion requires direct/backend live probes and a nonempty rollback target.
- Telegram remains `not_tested` until the existing bot returns the same correlation ID.
- Paid OpenAI API automatic fallback remains disabled.

## Immutable source chain

The production launcher is immutable and refuses repository or commit overrides.

- Launcher commit: `79ca156d87bfa1a8702dddc4783fc426c9fa9731`
- Reviewed runtime payload: `9ad70a02a2ab2ab0d54cf5ec30396f010f1cbbb6`
- Repository: `https://github.com/mnwersdfppa/no-cost-ai.git`

## Stage 1 — Pi preparation

Run this exact ASCII-only command in the Raspberry Pi terminal:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/79ca156d87bfa1a8702dddc4783fc426c9fa9731/android-node/bootstrap-all.sh)
```

The launcher:

1. rejects repository and commit overrides;
2. fetches only the reviewed runtime payload;
3. prepares locked Pi dependencies;
4. registers read-only MCP lanes first;
5. pushes the checksum-pinned Termux packet;
6. prepares the phone Codex backend;
7. prints the official OpenClaw mobile-node setup code.

It aborts on local source modifications, commit mismatch, package-integrity mismatch, multiple devices or unapproved USB debugging.

## Stage 2 — phone preparation

In Termux on the phone:

```bash
bash /sdcard/Download/openclaw-phone-bootstrap.sh
```

The secure wrapper verifies the official Codex artifact and the single Pi ED25519 key. The internal core cannot be run directly.

When Codex is not signed in:

```bash
codex login --device-auth
```

OAuth tokens remain on the phone and are not copied to GitHub, Telegram, Linear or Pi configuration files.

## Stage 3 — first SSH pin and live verification

Copy the `PHONE_SSH_HOST_KEY_SHA256=...` value shown directly on the phone into the Pi’s protected `phone-bridge.env`, then run:

```bash
RUN_LLM_TEST=1 ~/.openclaw/source/phone-absorber/android-node/verify-phone-bridge-secure.sh
```

The supported verifier:

- scans exactly one ED25519 host-key record;
- matches it against the operator-recorded fingerprint;
- atomically writes only that record on first use;
- rejects changed, duplicate or malformed keys;
- verifies forced-command denial;
- tests the phone Codex path and OpenClaw backend;
- records a rollback target before promotion;
- restarts and verifies the Gateway.

A successful T3 result remains `PARTIAL_T4_REQUIRED`.

## Stage 4 — existing Telegram bot

Send a correlation-tagged message to the **existing** OpenClaw Telegram bot. Do not create another bot, webhook owner or polling process. Completion requires the same correlation ID in the OpenClaw response and a redacted receipt.

## Optional task-scoped phone actions

```bash
~/.openclaw/source/phone-absorber/android-node/enable-phone-write-lane.sh
~/.openclaw/source/phone-absorber/android-node/disable-phone-write-lane.sh
```

Every enabled action remains allowlisted and approval-prompted.

## Verified rollback

```bash
~/.openclaw/source/phone-absorber/android-node/rollback-pi-phone-absorber-secure.sh
```

Rollback disables the plugin, removes bridge MCP registrations and the USB forward, restores the recorded pre-promotion model, restarts the Gateway and verifies the restored value. Phone data, pairings, OAuth files and Telegram configuration remain unchanged.

## Completion gates

- **T1:** official-source and design review.
- **T2:** immutable launcher/payload, Draft PR, pinned dependencies and security CI.
- **T3:** real Pi/phone installation and live backend probe with rollback evidence.
- **T4:** existing Telegram bot correlation-ID round trip.

PR #2 remains Draft until T3 and T4 receipts exist.
