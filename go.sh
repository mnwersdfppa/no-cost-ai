#!/usr/bin/env bash
set -euo pipefail
export INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
export AUTO_TYPE_TERMUX="${AUTO_TYPE_TERMUX:-1}"
URL='https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/feat/openclaw-android-node-absorber/android-node/bootstrap-one-line.sh'
bash <(curl -fsSL "$URL")
DEST="${OPENCLAW_PHONE_SOURCE:-$HOME/.openclaw/extensions/phone-absorber-src}"
exec "$DEST/android-node/auto-complete.sh"
