# Security policy for the OpenClaw Raspberry Pi / mobile bridge

## Scope

Security reports and reviews should prioritize:

- `android-node/**`
- `pi/**`
- OpenClaw Gateway, MCP and CLI-backend registrations
- Raspberry Pi ↔ Android USB/ADB and forced-command SSH boundaries
- Telegram single-poller invariants
- Supabase queue/JWT integration
- n8n, Make, Maton and Vercel integration packets

## Required security properties

1. **No root or jailbreak path**
   - No Magisk, bootloader unlock, custom ROM, `adb root`, `su -c` or privilege escalation.
   - The official OpenClaw mobile node is the primary device path.

2. **Single Telegram polling owner**
   - The existing OpenClaw Gateway is the only Telegram poller.
   - No second bot process, `getUpdates` loop or duplicate webhook owner may be introduced.

3. **Secrets stay out of source and evidence**
   - Never commit or print API keys, OAuth tokens, bot tokens, service-role keys, cookies or private keys.
   - Use local mode-0600 files, process environment or platform SecretRefs.
   - Receipts may contain only secret names and present/missing state, never values, prefixes or hashes.

4. **Immutable reviewed inputs**
   - Pi bootstrap sources use a reviewed 40-character Git commit.
   - npm dependencies use committed lockfiles and `npm ci`.
   - The phone Codex package uses a fixed version, tarball URL, integrity digest and shasum before local installation.

5. **Bounded phone capability surface**
   - Read-only status, screenshot and UI hierarchy are the default.
   - Production writes are limited to launching OpenClaw or Termux and HOME/BACK/WAKEUP/SLEEP.
   - No generic tap, swipe, URL, free-text input, arbitrary shell, install/uninstall, calls, messages, purchases, account changes or security-setting changes.

6. **Pinned identity and transport**
   - Exactly one Pi ED25519 public-key record is accepted by the phone packet.
   - Exactly one operator-verified Android SSH ED25519 host-key record is accepted by the Pi verifier.
   - A key change fails closed and requires an explicit re-pinning procedure.
   - ADB, SSH, MCP and the OpenClaw Gateway are not exposed directly to the public Internet.

7. **Safe model promotion and rollback**
   - Promotion requires successful direct and OpenClaw-backend live probes.
   - The pre-promotion primary model must be non-empty and differ from the target.
   - The rollback record is atomic and validated before promotion.
   - Rollback must verify the restored model and healthy Gateway before success.

8. **No automatic release authority**
   - AI and CI may create Draft PRs and validation artifacts.
   - No automatic merge, deployment, payment, credential mutation, account mutation or production phone action.

## Completion gates

- **T1:** official-source/design review.
- **T2:** isolated Draft PR, immutable dependencies, syntax/security scans, zero secret literals.
- **T3:** real Pi/phone execution with ADB, SSH, OAuth, direct/backend probe, Gateway and rollback evidence.
- **T4:** existing Telegram bot round trip with a correlation ID.

A green CI run, source commit, PR, local exit code or model response is not sufficient to claim T4 completion.

## Reporting

A valid report should include:

- affected commit and file/line range;
- preconditions and trust boundary;
- exact source-to-sink path;
- impact and realistic severity;
- a secret-free reproduction or proof;
- recommended bounded remediation and rollback.

Do not include live credentials or instructions that bypass authentication, rooting protections or device ownership checks.
