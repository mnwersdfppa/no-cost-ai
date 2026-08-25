#!/usr/bin/env bash
set -euo pipefail

PAIR_MODE="${PAIR_MODE:-limited}"
REMOTE="${REMOTE:-0}"

command -v openclaw >/dev/null 2>&1 || { echo "BLOCKED=OPENCLAW_NOT_FOUND"; exit 40; }
openclaw doctor --fix || openclaw doctor || true
openclaw gateway status || true

args=(qr --setup-code-only)
if [[ "$REMOTE" == "1" ]]; then
  args+=(--remote)
fi
case "$PAIR_MODE" in
  limited) args+=(--limited) ;;
  voice) args+=(--voice-node) ;;
  full) ;;
  *) echo "BLOCKED=INVALID_PAIR_MODE"; exit 41 ;;
esac

echo "SETUP_CODE_BEGIN"
openclaw "${args[@]}"
echo "SETUP_CODE_END"
echo "PHONE_ACTION=Open the official OpenClaw Android or iOS app, open Settings/Gateway or Connect, and paste the setup code."
echo "VERIFY_AFTER_PAIRING=openclaw devices list && openclaw nodes status"
openclaw devices list || true
