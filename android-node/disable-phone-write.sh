#!/usr/bin/env bash
set -euo pipefail
openclaw mcp configure android-phone-actions --disable
openclaw mcp reload || true
if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
  openclaw gateway restart --safe || true
else
  openclaw gateway restart || true
fi
echo "RESULT=PHONE_ACTIONS_DISABLED"
