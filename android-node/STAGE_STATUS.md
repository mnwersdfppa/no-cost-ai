# Staged implementation status — 2026-08-18

## Stage 0 — decision

- Jailbreak/root: not required and not applied.
- Raspberry Pi 5 remains the single OpenClaw Gateway and Telegram poller.
- The phone is a paired node and optional bounded runtime, never a second Telegram relay.

## Stage 1 — source absorption and predeployment

Status: **PASS**

- Official OpenClaw Android/iOS node pairing prepared.
- No-root ADB MCP status, inspection and disabled-by-default action lanes prepared.
- Android Termux forced-command SSH bridge prepared.
- Phone Codex CLI backend `phone-codex-cli/gpt-5.6-sol` prepared.
- OAuth remains on the phone; API-key and proxy environment variables are stripped.
- Codex local shell, image, web, apps, plugins, code mode, collaboration, multi-agent, image-generation and artifact surfaces are disabled with strict config.
- Exact direct/backend live-test gates are required before model promotion.
- Rollback restores the recorded previous primary model.
- CI and secret/high-risk primitive checks are required.

## Stage 2 — physical Pi/phone verification

Status: **PENDING**

Required evidence:

1. Pi sees exactly one intended Android ADB device, or official mobile-node pairing succeeds.
2. USB-forwarded SSH host key is pinned.
3. Forced-command denial test passes.
4. Phone Codex reports ChatGPT authentication.
5. Exact direct response `PHONE_CODEX_OK` passes.
6. Exact OpenClaw backend response `PHONE_BACKEND_OK` with provider `phone-codex-cli` passes.
7. Primary model changes only after all preceding checks pass.

## Stage 3 — Telegram round trip

Status: **PENDING**

The existing OpenClaw Telegram bot must receive one ordinary user message and return a reply through the promoted phone-backed model. No second poller or relay may be created.

## Merge gate

PR remains Draft and unmerged until Stage 2 and Stage 3 produce receipts.
