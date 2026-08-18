#!/usr/bin/env bash
set -euo pipefail

SRC="${PHONE_ABSORBER_SOURCE:-$HOME/.openclaw/source/phone-absorber}"
REPO="${PHONE_ABSORBER_REPO:-https://github.com/mnwersdfppa/no-cost-ai.git}"
REF="${PHONE_ABSORBER_REF:-feat/openclaw-android-node-absorber}"
ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
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

set +e
BRIDGE_OUTPUT="$(INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}" ./install-pi-bridge.sh 2>&1)"
BRIDGE_STATUS=$?
set -e
printf '%s\n' "$BRIDGE_OUTPUT"

if [[ $BRIDGE_STATUS -ne 0 ]]; then
  # An iPhone, an Android phone without USB debugging, or a phone reachable only
  # over the network can still use the official OpenClaw mobile node. Do not
  # weaken device security or attempt a jailbreak/root fallback.
  if grep -qE 'BLOCKED=(NO_ANDROID_DEVICE|ADB_UNAUTHORIZED)' <<<"$BRIDGE_OUTPUT"; then
    ./pair-openclaw-node.sh || true
    printf '%s\n' \
      'RESULT=OFFICIAL_MOBILE_NODE_PREPARED' \
      'USB_RUNTIME=NOT_READY' \
      'JAILBREAK_ROOT=NOT_REQUIRED' \
      'NEXT=pair the official OpenClaw Android or iOS app with the printed setup code'
    exit 0
  fi
  echo "RESULT=BLOCKED"
  exit "$BRIDGE_STATUS"
fi

# Ensure the managed CLI backend is linked through the supported local path.
if ! openclaw plugins inspect phone-codex-cli --runtime >/dev/null 2>&1; then
  openclaw plugins install -l "$ROOT/phone-codex-cli-backend"
fi
openclaw plugins enable phone-codex-cli || true
openclaw plugins inspect phone-codex-cli --runtime || true

./pair-openclaw-node.sh || true

printf '%s\n' \
  'RESULT=STAGE_1_PREPARED' \
  'JAILBREAK_ROOT=NOT_REQUIRED' \
  'NEXT_PHONE_COMMAND=bash /sdcard/Download/openclaw-phone-bootstrap.sh' \
  "NEXT_PI_COMMAND=RUN_LLM_TEST=1 $SRC/android-node/verify-phone-bridge.sh"
