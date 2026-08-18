#!/usr/bin/env bash
set -euo pipefail

SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
[[ -r "$ENV_FILE" ]] || { echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING"; exit 50; }

openclaw mcp configure android-phone-write --enable --approval approve --probe
if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
  openclaw gateway restart --safe
else
  openclaw gateway restart
fi
echo "RESULT=PHONE_WRITE_MCP_ENABLED"
echo "POLICY=allowlisted tools only; no calls, SMS, purchases, installs, uninstalls, or arbitrary shell"
