#!/usr/bin/env bash
set -euo pipefail

command -v openclaw >/dev/null 2>&1 || { echo 'ERROR: openclaw is required' >&2; exit 1; }
SERVER_NAME="${MATON_MCP_NAME:-maton-readonly}"
openclaw mcp unset "$SERVER_NAME"
openclaw mcp reload || true

echo "MATON_MCP_REMOVED=$SERVER_NAME"
echo 'Maton account connections were not deleted.'
echo 'OAuth revocation, when needed, must be performed explicitly in Maton/account settings.'
