# Staged implementation status — 2026-08-19

## Stage 0 — decision

- Jailbreak/root/Magisk/bootloader changes/custom ROM: **not required, not applied, out of scope**.
- Raspberry Pi 5 remains the single OpenClaw Gateway and Telegram poller.
- The phone is a paired node and optional bounded runtime, never a second Telegram relay.
- No automatic merge, production deployment, payment, credential mutation or production phone action.

## Stage 1 — S-rank absorption and predeployment

Status: **PASS**

- Official OpenClaw Android/iOS node pairing prepared.
- No-root ADB MCP status and inspection lanes prepared.
- Optional phone write lane reduced to OpenClaw/Termux launch plus HOME/BACK/WAKEUP/SLEEP.
- Generic URL, tap, swipe, free-text input and arbitrary `adb shell` tools removed.
- Android Termux forced-command SSH bridge prepared.
- Pi public-key input requires exactly one valid ED25519 record.
- First Android host-key pinning requires exactly one scanned ED25519 record, matches the operator-recorded SHA256 fingerprint and atomically writes only that record.
- Changed, duplicate, malformed or non-ED25519 host keys fail closed.
- Phone Codex CLI backend `phone-codex-cli/gpt-5.6-sol` prepared.
- Official `@openai/codex` fixed at `0.146.0`; tarball URL, integrity and shasum are pinned before installation.
- npm dependencies use committed lockfiles and `npm ci` in supported install and validation paths.
- Production source identity is fixed:
  - repository: `https://github.com/mnwersdfppa/no-cost-ai.git`
  - immutable launcher: `79ca156d87bfa1a8702dddc4783fc426c9fa9731`
  - reviewed runtime payload: `9ad70a02a2ab2ab0d54cf5ec30396f010f1cbbb6`
- Repository and payload overrides are rejected by the production launcher.
- Legacy phone, verifier and rollback cores are internal-only and require the hardened wrappers.
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
5. Android secure entrypoint checks

## Stage 2 — physical Pi/phone verification

Status: **PENDING**

Required evidence:

1. Pi sees exactly one intended Android ADB device, or official mobile-node pairing succeeds.
2. Immutable launcher and payload verification passes.
3. The secure phone packet validates the Codex package and exactly one Pi ED25519 key.
4. The fingerprint displayed directly on the phone is recorded in protected Pi configuration.
5. Secure first-pin provisioning writes exactly one matching ED25519 host-key record.
6. Forced-command denial test passes.
7. Phone Codex reports ChatGPT authentication.
8. Exact direct response `PHONE_CODEX_OK` passes.
9. Exact OpenClaw backend response `PHONE_BACKEND_OK` with provider `phone-codex-cli` passes.
10. Gateway health, model promotion and rollback-record verification pass.

Production Stage 1 command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/79ca156d87bfa1a8702dddc4783fc426c9fa9731/android-node/bootstrap-all.sh)
```

Supported Stage 3 verifier:

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
- Maton is staged as browser-OAuth read-only discovery through the official remote MCP.
- Paid OpenAI API automatic fallback remains disabled; free/local routes remain separate.
- Deterministic GitHub/Supabase validation is bounded to the approved stop time.

## Merge/completion gate

PR #2 remains Draft and unmerged until physical Stage 2 and Telegram Stage 3 receipts exist. Green CI, a PR, source code, model output or process exit code alone is not completion.
