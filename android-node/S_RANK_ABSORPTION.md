# OpenClaw Android Node Absorption — S Rank

## Decision

Do not jailbreak or root the phone as the default path. The official OpenClaw Android node already pairs with a Raspberry Pi/Linux Gateway, and ADB/scrcpy provide a no-root operator fallback. Rooting expands the attack surface, weakens app isolation, and is not required for the target workflow.

## S-rank components absorbed

### S1 — `openclaw/openclaw` official Android node

Primary path. Pair the official Android companion app to the Raspberry Pi 5 OpenClaw Gateway. It provides durable chat, node presence, camera/screen/location capabilities subject to Android permissions, and keeps the Gateway as the single control plane.

Absorbed capabilities:
- device pairing and reconnect
- Android as an OpenClaw node, not a second Telegram poller
- durable phone chat/outbox
- node capability discovery and invocation
- secure setup-code flow

### S2 — `Genymobile/scrcpy` + Android platform-tools

Operator fallback over USB ADB. No root or companion APK is required. Used only when the official node surface cannot complete a UI task.

Absorbed capabilities:
- device presence and health
- screenshot and UI hierarchy inspection
- allowlisted app launch
- optional approval-gated input actions

### S3 — `termux/termux-app`, `termux/termux-api`, `termux/termux-boot`

Optional phone-side shell and sensor runtime. Install all Termux apps/plugins from the same source/signing channel. This lane is latent and loaded only when the official OpenClaw node cannot expose a required phone API.

### S4 — `tailscale/tailscale`

Private network path for secure `wss://` Gateway access and remote ADB. Never expose ADB port 5555 or the OpenClaw Gateway directly to the public Internet.

## Conditional A-rank

### `RikkaApps/Shizuku`

Use only for a specific Android system API that ADB/official node/Termux cannot provide. It starts with ADB privileges and does not require root, but permissions vary by Android version. It is not installed automatically.

## Rejected from automatic absorption

- random one-command OpenClaw Android installers
- Android MCP servers exposing unrestricted `adb shell`
- public HTTP MCP endpoints
- root/jailbreak/custom-ROM changes
- automatic sending of messages, calls, purchases, account changes, or security-setting changes

## Operating contract

1. Raspberry Pi 5 remains the OpenClaw Gateway and Telegram single poller.
2. Android is a paired node and optional actuator.
3. Read-only checks may run automatically.
4. Side effects are restricted to an allowlist and remain disabled unless explicitly enabled.
5. High-risk phone actions are not implemented.
6. Secrets never enter GitHub, Linear, Telegram messages, logs, or command arguments.
7. Every change is reversible: remove the MCP registration, revoke the Android device, or disconnect ADB.
