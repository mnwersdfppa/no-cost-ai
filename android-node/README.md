# OpenClaw mobile runtime bridge for Raspberry Pi 5

This package turns a USB-connected mini Android phone into a bounded OpenClaw companion and, when Codex works on the phone but not on the Pi, into a subscription-backed text backend. **Root/jailbreak is not required.**

## Architecture

```text
Telegram (one existing poller)
  -> Raspberry Pi 5 OpenClaw Gateway
     -> official OpenClaw Android/iOS node (primary device lane)
     -> USB ADB MCP status/inspection/actions (bounded fallback)
     -> phone-codex-cli/gpt-5.6-sol (phone Termux + ChatGPT/Codex login)
```

The phone never becomes a second Telegram poller. The Pi remains the single Gateway and routing owner.

## Why no jailbreak/root

The official OpenClaw mobile app connects to a Linux Gateway and exposes node capabilities. Android ADB/scrcpy and Termux also work without root for this design. Root would weaken app isolation and recovery without solving the routing problem.

## S-rank absorption

- `openclaw/openclaw`: official Android/iOS nodes, setup-code pairing, durable chat and device capabilities.
- `openai/codex`: official phone-side Codex CLI and ChatGPT subscription login.
- OpenClaw CLI backend plugin API: presents the phone runtime as `phone-codex-cli/gpt-5.6-sol`, so normal Telegram turns can use it directly.
- `Genymobile/scrcpy` + Android platform-tools: no-root USB inspection/control fallback.
- `termux/termux-app`, `termux-api`, `termux-boot`: phone shell/API/startup lane.
- `modelcontextprotocol/typescript-sdk`: local stdio MCP servers with annotations and allowlists.
- `tailscale/tailscale`: private remote transport; ADB and MCP are never exposed publicly.

`RikkaApps/Shizuku` remains conditional A-rank for a proven capability gap. Third-party root, Magisk, custom-ROM and unofficial Codex binary installers are excluded from automatic absorption.

## Prepared lanes

### Official mobile node

Use the setup code printed by `pair-openclaw-node.sh` in the official OpenClaw Android or iOS app.

### ADB MCP

- `android-phone-status`: status only; annotation-aware automatic approval.
- `android-phone-inspect`: screenshot/UI hierarchy; approval required.
- `android-phone-actions`: allowlisted UI actions; disabled initially and approval required when enabled.

No arbitrary `adb shell` tool exists. Calls, SMS, purchases, app install/uninstall and security-setting changes are not implemented.

### Phone Codex CLI backend

The Pi uses USB-forwarded SSH to Termux. The SSH key is forced-command restricted, port forwarding/PTY/agent forwarding are denied, and only two remote commands exist: status and the fixed Codex runner. The runner:

- accepts only `{model,prompt}` JSON through stdin
- allowlists `gpt-5.6-sol` and `gpt-5.6`
- removes API-key environment variables, preserving the phone's ChatGPT/Codex OAuth path
- uses ephemeral read-only/no-approval Codex flags when supported
- runs inside an empty non-writable work directory
- enforces prompt and wall-clock limits
- exposes no arbitrary shell

After a real live test, OpenClaw promotes `phone-codex-cli/gpt-5.6-sol` to the primary model and records the previous primary for rollback.

## Fast staged installation

### Stage 1 — Pi preparation

Run this one line in the Raspberry Pi terminal:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/feat/openclaw-android-node-absorber/android-node/bootstrap-all.sh)
```

It installs/prepares ADB, MCP lanes, the CLI backend plugin, pushes the phone bootstrap file, and prints an official mobile-node setup code.

### Stage 2 — phone preparation

In Termux on the phone:

```bash
bash /sdcard/Download/openclaw-phone-bootstrap.sh
```

When Codex is not signed in:

```bash
codex login --device-auth
```

Approve the short-lived code in the phone browser.

### Stage 3 — verification and promotion

Back on the Pi:

```bash
RUN_LLM_TEST=1 ~/.openclaw/source/phone-absorber/android-node/verify-phone-bridge.sh
```

Success requires: ADB, pinned SSH host key, forced-command denial test, ChatGPT login, direct phone Codex response, OpenClaw CLI backend response and primary-model promotion.

### Stage 4 — Telegram

Send a normal message to the existing OpenClaw Telegram bot. Do not create a second bot process or poller.

## Optional phone actions

```bash
~/.openclaw/source/phone-absorber/android-node/enable-phone-write.sh
~/.openclaw/source/phone-absorber/android-node/disable-phone-write.sh
```

Every enabled action remains allowlisted and approval-prompted.

## Rollback

```bash
~/.openclaw/source/phone-absorber/android-node/rollback-pi-phone-absorber.sh
```

Rollback disables the plugin, removes bridge MCP registrations, removes the local USB forward and restores the recorded previous primary model. Phone data, apps, pairings, OAuth files and Telegram configuration remain unchanged.

## Completion gates

- T1: official-source and design review
- T2: separate branch, static checks, no secret literals, forced-command SSH
- T3: real Pi/phone install and live backend probe
- T4: existing Telegram bot round trip with `phone-codex-cli/gpt-5.6-sol`

Code or PR existence is not T4 completion.
