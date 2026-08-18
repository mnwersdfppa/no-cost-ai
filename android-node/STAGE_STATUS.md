# Staged implementation status — 2026-08-19

## Stage 0 — decision

- Jailbreak/root/Magisk/bootloader changes/custom ROM: **not required, not applied, out of scope**.
- Raspberry Pi 5 remains the single OpenClaw Gateway and Telegram poller.
- The phone is a paired node and optional bounded runtime, never a second Telegram relay.
- No automatic merge, deployment, payment, credential mutation or production phone action.

## Stage 1 — S-rank absorption and predeployment

Status: **PASS**

- Official OpenClaw Android/iOS node pairing prepared.
- No-root ADB MCP status and inspection lanes prepared.
- Optional production write lane reduced to OpenClaw/Termux launch plus HOME/BACK/WAKEUP/SLEEP.
- Generic URL, tap, swipe, free-text input and arbitrary `adb shell` tools removed.
- Android Termux forced-command SSH bridge prepared.
- Pi public-key input requires exactly one valid ED25519 record.
- Phone SSH trust requires exactly one operator-verified ED25519 host-key record.
- Phone Codex CLI backend `phone-codex-cli/gpt-5.6-sol` prepared.
- Official `@openai/codex` fixed at `0.146.0`; tarball URL, integrity and shasum are pinned before local installation.
- npm dependencies use committed lockfiles and `npm ci` in CI/install paths.
- Pi bootstrap requires a reviewed immutable 40-character Git commit; reviewed installation commit is `ff1f0b77d2a997bd5ef0b21d847eb2a31819ecdc`.
- OAuth remains on the phone; API-key and proxy environment variables are stripped.
- Codex local shell, image, web, apps, plugins, code mode, collaboration, multi-agent, image-generation and artifact surfaces are disabled with strict config.
- Direct/backend live-test gates are required before model promotion.
- Promotion requires a non-empty rollback target differing from the phone backend.
- Secure rollback verifies the restored primary model and healthy Gateway.
- Verification receipts keep Telegram at `not_tested` until a real T4 correlation-ID round trip.

Validation workflows required on the latest Android source change:

1. Android Node Absorber CI
2. android-phone-absorber-ci
3. Android node safety checks
4. Android immutable live-gate checks

## Stage 2 — physical Pi/phone verification

Status: **PENDING**

Required evidence:

1. Pi sees exactly one intended Android ADB device, or official mobile-node pairing succeeds.
2. Immutable source commit verification passes.
3. The secure phone packet validates the Codex package and exactly one Pi ED25519 key.
4. Exactly one USB-forwarded SSH ED25519 host key matches the operator-recorded SHA256 fingerprint.
5. Forced-command denial test passes.
6. Phone Codex reports ChatGPT authentication.
7. Exact direct response `PHONE_CODEX_OK` passes.
8. Exact OpenClaw backend response `PHONE_BACKEND_OK` with provider `phone-codex-cli` passes.
9. Gateway health passes.
10. Primary promotion and rollback-record verification pass.

The only supported verifier is:

```bash
RUN_LLM_TEST=1 ~/.openclaw/source/phone-absorber/android-node/verify-phone-bridge-secure.sh
```

## Stage 3 — existing Telegram round trip

Status: **PENDING**

The existing OpenClaw Telegram bot must receive one correlation-tagged ordinary user message and return a response carrying the same correlation ID through the phone-backed model. No second poller, relay or competing webhook owner may be created.

## Automation preparation

Status: **PREPARED, NOT PHYSICALLY ACTIVATED**

- Supabase bounded work queue and JWT-protected Pi worker endpoint are prepared.
- Pi systemd timer and n8n/Make packets are prepared but require a current Pi JWT and local installation.
- Maton is limited to disabled read-only discovery until a runtime-local credential and endpoint/scope checks pass.
- Paid OpenAI API fallback remains disabled by default; free/local routes remain separate.

## Merge/completion gate

PR #2 remains Draft and unmerged until physical Stage 2 and Telegram Stage 3 receipts exist. Green CI, a PR, source code, model output or process exit code alone is not completion.
