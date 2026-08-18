# OpenClaw Android Node + Phone Runtime Bridge

This package turns an Android phone attached to a Raspberry Pi 5 into bounded OpenClaw capabilities **without rooting or jailbreaking it**.

## Architecture

```text
Telegram (one existing poller)
  -> Raspberry Pi 5 OpenClaw Gateway
     -> official OpenClaw Android node (primary)
     -> android-phone-read MCP over USB ADB (automatic read-only fallback)
     -> android-phone-write MCP over USB ADB (disabled by default, approval gated)
     -> phone-codex MCP over USB-forwarded SSH to Termux (conditional)
```

The phone never becomes a second Telegram poller. The Pi remains the single Gateway and routing owner.

## Why no jailbreak/root

The official OpenClaw Android node, ADB/scrcpy and Termux all work without root for this design. Root would weaken Android app isolation, expand the attack surface and complicate recovery without solving the core OpenClaw routing problem.

## S-rank absorption

- `openclaw/openclaw`: official Android companion node, durable chat/outbox, Gateway pairing and device capabilities.
- `Genymobile/scrcpy` + Android platform-tools: no-root USB/TCP inspection and operator fallback.
- `termux/termux-app`, `termux-api`, `termux-boot`: optional phone shell/API/startup lane.
- `tailscale/tailscale`: private remote transport; never expose ADB or MCP publicly.
- `modelcontextprotocol/typescript-sdk`: local stdio MCP servers with tool allowlists.
- `openai/codex`: optional phone-side subscription runtime only when the official CLI is executable and `codex login status` confirms ChatGPT authentication.

`RikkaApps/Shizuku` remains conditional A-rank for a documented capability gap. Third-party OpenClaw/Codex-on-Termux installers are not installed automatically.

## Prepared capabilities

### Automatic read-only

- phone connection, model, Android version, battery and current activity
- screenshot
- UI hierarchy
- official Android node status

### Present but disabled

- app launch from a package allowlist
- HTTPS URL launch
- HOME/BACK/WAKEUP/SLEEP
- tap, swipe and restricted ASCII input

The code does **not** implement calls, SMS, purchases, installation, uninstallation, security-setting changes or arbitrary `adb shell`.

### Conditional phone Codex

When the official Codex CLI runs in Termux and is signed in with ChatGPT, OpenClaw can call a fixed remote runner through USB-forwarded SSH. The runner:

- accepts only `{model,prompt}` JSON
- allowlists `gpt-5.6-sol` and `gpt-5.6`
- uses ephemeral, read-only, no-approval execution flags when available
- runs in a dedicated empty directory
- enforces a wall-clock timeout and process-group termination
- leaves OAuth credentials on the phone
- rejects arbitrary remote commands

This route stays disabled until the verification script passes.

## Fast installation

Clone this branch on the Pi and run:

```bash
git clone -b feat/openclaw-android-node-absorber https://github.com/mnwersdfppa/no-cost-ai.git
cd no-cost-ai/android-node
chmod +x *.sh
./install-pi-bridge.sh
```

The installer pushes one bootstrap script and the Pi public SSH key to the phone. In Termux, run:

```bash
bash /sdcard/Download/openclaw-phone-bootstrap.sh
```

When Codex is not signed in:

```bash
codex login --device-auth
```

Approve the code in the phone browser. Then on the Pi:

```bash
RUN_LLM_TEST=1 ./verify-phone-bridge.sh
```

Pair the official Android node:

```bash
./pair-openclaw-node.sh
```

Paste the setup code into the official OpenClaw Android app.

## Write gate

Write MCP is not enabled during installation.

```bash
./enable-phone-write.sh
./disable-phone-write.sh
```

Even when enabled, tools remain allowlisted and approval-gated.

## Official Android APK lane

`install-openclaw-android.sh` downloads release assets from `openclaw/openclaw`, verifies SHA-256 and GitHub attestation when supported, and uses `adb install -r`. It never auto-uninstalls an existing app when signing channels conflict.

## Rollback

```bash
./rollback-pi-bridge.sh
```

This removes only the three OpenClaw MCP definitions and USB port forward. Files are retained for inspection unless `DELETE_FILES=1` is explicitly used.

## Completion gates

- T1: official source and security/license review
- T2: separate branch, static checks, no secret literals
- T3: real Pi install, ADB + SSH + MCP probes, Android pairing
- T4: existing Telegram bot round trip through OpenClaw with receipts

Code or PR existence is not T4 completion.
