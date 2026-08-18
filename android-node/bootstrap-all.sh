#!/usr/bin/env bash
set -euo pipefail

SRC="${PHONE_ABSORBER_SOURCE:-$HOME/.openclaw/source/phone-absorber}"
REPO="${PHONE_ABSORBER_REPO:-https://github.com/mnwersdfppa/no-cost-ai.git}"
REF="${PHONE_ABSORBER_REF:-feat/openclaw-android-node-absorber}"
mkdir -p "$(dirname "$SRC")"

if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" fetch --quiet origin "$REF"
  git -C "$SRC" checkout --quiet "$REF"
  git -C "$SRC" reset --hard --quiet "origin/$REF"
else
  git clone --quiet --depth 1 --branch "$REF" "$REPO" "$SRC"
fi

cd "$SRC/android-node"
chmod 700 ./*.sh phone-codex-cli-backend/phone-codex-cli-backend.sh
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}" ./install-pi-bridge.sh
./pair-openclaw-node.sh || true

printf '%s\n' \
  'RESULT=STAGE_1_PREPARED' \
  'JAILBREAK_ROOT=NOT_REQUIRED' \
  'NEXT_PHONE_COMMAND=bash /sdcard/Download/openclaw-phone-bootstrap.sh' \
  "NEXT_PI_COMMAND=RUN_LLM_TEST=1 $SRC/android-node/verify-phone-bridge.sh"
