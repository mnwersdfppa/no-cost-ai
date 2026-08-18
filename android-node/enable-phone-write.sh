#!/usr/bin/env bash
set -euo pipefail

SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
[[ -r "$ENV_FILE" ]] || { echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING"; exit 50; }

openclaw mcp configure android-phone-actions --enable --approval prompt --probe
openclaw mcp reload || true
if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
  openclaw gateway restart --safe
else
  openclaw gateway restart
fi
echo "RESULT=PHONE_ACTIONS_ENABLED"
echo "APPROVAL=REQUIRED_EACH_CALL"
echo "POLICY=allowlisted tools only; no calls, SMS, purchases, installs, uninstalls, security changes, or arbitrary shell"
