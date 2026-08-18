# OpenClaw mobile runtime bridge for Raspberry Pi 5

This package turns a USB-connected mini Android phone into a bounded OpenClaw companion and, when the official Codex CLI works on the phone but not on the Pi, into a subscription-backed text backend. **Root, jailbreak, Magisk, bootloader changes and custom ROMs are not required or used.**

## Architecture

```text
Telegram (one existing poller)
  -> Raspberry Pi 5 OpenClaw Gateway
     -> official OpenClaw Android/iOS node (primary device lane)
     -> USB ADB MCP status/inspection (bounded fallback)
     -> phone-codex-cli/gpt-5.6-sol (Termux + ChatGPT/Codex login)
```

The phone never becomes a second Telegram poller. The Pi remains the single Gateway and routing owner.

## S-rank absorption

- `openclaw/openclaw`: official Android/iOS node, setup-code pairing and device capabilities.
- `openai/codex`: official phone-side Codex CLI and ChatGPT subscription login.
- OpenClaw CLI backend API: presents the constrained phone runtime as `phone-codex-cli/gpt-5.6-sol`.
- `Genymobile/scrcpy` + Android platform-tools: no-root USB inspection fallback.
- `termux/termux-app`, `termux-api`, `termux-boot`: phone shell/API/startup lane.
- `modelcontextprotocol/typescript-sdk`: local stdio MCP servers with annotations and allowlists.
- `tailscale/tailscale`: private remote transport; ADB and MCP are never exposed publicly.

`RikkaApps/Shizuku` remains conditional only for a proven capability gap. Third-party root tools and unofficial Codex installers are excluded.

## Security boundaries

- No arbitrary `adb shell` tool.
- Production phone writes are limited to launching OpenClaw or Termux and HOME/BACK/WAKEUP/SLEEP.
- Generic URL launch, taps, swipes and free-form text input are not registered with OpenClaw.
- Calls, SMS, purchases, app install/uninstall, account changes and security-setting changes are not implemented.
- The Pi public key must be exactly one valid ED25519 record.
- The phone SSH host key must be exactly one operator-verified ED25519 record.
- `@openai/codex` is fixed at `0.146.0`; npm integrity, SHA-1 and tarball URL are pinned before installation.
- API-key environment variables are removed from the phone-backed inference process.
- Promotion requires direct/backend live probes plus a valid non-empty rollback target.
- T3 never claims Telegram completion; T4 requires a real correlation-ID round trip through the existing bot.

## Stage 1 — immutable Pi preparation

Run this exact command in the Raspberry Pi terminal. Both the downloaded bootstrap script and the repository checkout are pinned to the reviewed commit.

```bash
PHONE_ABSORBER_COMMIT=ff1f0b77d2a997bd5ef0b21d847eb2a31819ecdc bash <(curl -fsSL https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/ff1f0b77d2a997bd5ef0b21d847eb2a31819ecdc/android-node/bootstrap-all.sh)
```

The bootstrap:

1. verifies the immutable source commit;
2. prepares ADB and locked npm dependencies;
3. registers read-only MCP lanes first;
4. pushes the checksum-pinned Termux packet;
5. prepares the phone Codex backend plugin;
6. prints an official OpenClaw mobile-node setup code.

It aborts on local source modifications, commit mismatch, missing lockfiles, package-integrity mismatch, multiple devices or unapproved USB debugging.

## Stage 2 — phone preparation

In Termux on the phone:

```bash
bash /sdcard/Download/openclaw-phone-bootstrap.sh
```

The secure wrapper verifies the official Codex package and the single Pi ED25519 key before running the constrained core bootstrap.

When Codex is not signed in:

```bash
codex login --device-auth
```

Approve the short-lived code in the phone browser. OAuth tokens remain on the phone and are not copied to GitHub, Telegram, Linear or the Pi configuration.

## Stage 3 — verification and safe promotion

Back on the Pi:

```bash
RUN_LLM_TEST=1 ~/.openclaw/source/phone-absorber/android-node/verify-phone-bridge-secure.sh
```

Success requires:

- ADB device ready;
- exactly one pinned ED25519 SSH host key matching the operator-recorded SHA256 fingerprint;
- forced-command denial test;
- ChatGPT/Codex login;
- direct phone Codex response;
- OpenClaw CLI backend response;
- healthy Gateway;
- verified non-empty rollback target before promotion.

The result remains `PARTIAL_T4_REQUIRED` after T3.

## Stage 4 — existing Telegram bot

Send a correlation-tagged message to the existing OpenClaw Telegram bot. Do not create a second bot, webhook owner or polling process. Completion requires the same correlation ID in the received OpenClaw response and a receipt containing no token or secret material.

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

Rollback disables the plugin, removes bridge MCP registrations and the USB forward, restores the recorded pre-promotion primary model, restarts the Gateway and verifies the restored value. Phone data, apps, pairings, OAuth files and Telegram configuration remain unchanged.

## Completion gates

- **T1:** official-source and design review.
- **T2:** isolated Draft PR, immutable dependencies, syntax/security scans, no secret literals.
- **T3:** real Pi/phone installation and live backend probe with rollback evidence.
- **T4:** existing Telegram bot round trip with a correlation ID.

Code, CI, PR or a successful local command alone is not T4 completion. PR #2 remains Draft until T3 and T4 receipts exist.
