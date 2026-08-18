# OpenClaw phone absorber for Raspberry Pi 5

This package turns a USB-connected phone into a safe OpenClaw companion without rooting or jailbreaking it.

## Architecture

1. **Primary:** official OpenClaw Android/iOS node paired to the existing Raspberry Pi Gateway.
2. **Fallback:** local USB ADB MCP server with strict tool allowlists.
3. **Optional:** Termux/Termux:API over USB-forwarded SSH for a specific capability gap.
4. **Conditional:** Shizuku only after a documented unmet requirement.

Telegram remains connected to one OpenClaw Gateway poller. The phone is a node/actuator, not another Telegram bot process.

## Install on Raspberry Pi

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/feat/openclaw-android-node-absorber/android-node/install-pi-phone-absorber.sh)
```

The installer prints a short-lived OpenClaw mobile setup code and registers three local MCP lanes:

- `android-phone-status`: status only; annotation-aware auto approval.
- `android-phone-inspect`: screenshot/UI hierarchy; explicit approval.
- `android-phone-actions`: allowlisted UI actions; explicit approval.

No arbitrary `adb shell` tool is exposed.

## Test

Ask OpenClaw:

```text
Check the connected phone status. Do not reveal secrets.
```

Then test inspection with explicit approval:

```text
Take a screenshot of the connected phone and describe only the current app and visible error.
```

For an action test, use a reversible action:

```text
After approval, press HOME on the connected phone, then confirm the foreground activity.
```

## Rollback

```bash
~/.openclaw/extensions/phone-absorber/android-node/rollback-pi-phone-absorber.sh
```

Rollback removes only the three MCP registrations. It does not delete phone data, apps, pairings or Telegram configuration.
