# Optional Termux fallback (no root)

Use this lane only when the official OpenClaw mobile node and the USB ADB MCP do not expose a required phone capability.

## Components

Install Termux, Termux:API and Termux:Boot from the same source/signing channel. Do not mix F-Droid, GitHub and Play builds. Root is not required.

The safe transport is local USB only:

1. Termux runs `sshd` with public-key authentication on port 8022.
2. Raspberry Pi runs `adb forward tcp:8022 tcp:8022`.
3. Pi connects only to `127.0.0.1:8022`; no public listener is created.
4. OpenClaw must call an allowlisted phone agent, never an unrestricted shell.

## Allowed candidate capabilities

- battery/status
- location after Android permission
- local notification
- TTS playback
- camera capture after Android permission

## Explicitly excluded

- arbitrary shell tool
- SMS/call sending
- purchases
- account or security-setting changes
- app install/uninstall
- root, Magisk, jailbreak or custom-ROM changes
- secret extraction

Shizuku remains conditional A-rank only for a specific API gap. It is not installed automatically.
