#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/mnwersdfppa/no-cost-ai.git"
BRANCH="feat/openclaw-android-node-absorber"
DEST="${OPENCLAW_PHONE_SOURCE:-$HOME/.openclaw/extensions/phone-absorber-src}"

command -v git >/dev/null 2>&1 || { echo "BLOCKED=GIT_NOT_FOUND"; exit 70; }
mkdir -p "$(dirname "$DEST")"
chmod 700 "$(dirname "$DEST")" 2>/dev/null || true

if [[ -d "$DEST/.git" ]]; then
  git -C "$DEST" fetch --depth 1 origin "$BRANCH"
  git -C "$DEST" checkout -B "$BRANCH" FETCH_HEAD
else
  rm -rf "$DEST"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$DEST"
fi

cd "$DEST/android-node"
chmod +x ./*.sh
./install-pi-bridge.sh

echo "NEXT_PHONE=bash /sdcard/Download/openclaw-phone-bootstrap.sh"
echo "NEXT_PI=RUN_LLM_TEST=1 $DEST/android-node/verify-phone-bridge.sh"
echo "PAIR_ANDROID=$DEST/android-node/pair-openclaw-node.sh"
