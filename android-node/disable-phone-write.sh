#!/usr/bin/env bash
set -euo pipefail
openclaw mcp configure android-phone-write --disable
if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
  openclaw gateway restart --safe || true
else
  openclaw gateway restart || true
fi
echo "RESULT=PHONE_WRITE_MCP_DISABLED"
