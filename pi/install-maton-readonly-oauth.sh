#!/usr/bin/env bash
set -euo pipefail

command -v openclaw >/dev/null 2>&1 || { echo 'ERROR: openclaw is required' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'ERROR: python3 is required' >&2; exit 1; }

SERVER_NAME="${MATON_MCP_NAME:-maton-readonly}"
MCP_JSON="$(python3 - <<'PY'
import json
print(json.dumps({
  "url": "https://mcp.maton.ai",
  "transport": "streamable-http",
  "auth": "oauth",
  "enabled": True,
  "connectionTimeoutMs": 10000,
  "requestTimeoutMs": 30000,
  "toolFilter": {
    "include": [
      "whoami",
      "list_connections",
      "get_connection",
      "search_apps",
      "search_actions",
      "get_action"
    ],
    "exclude": [
      "create_connection",
      "delete_connection",
      "run_action",
      "api"
    ]
  },
  "codex": {"defaultToolsApprovalMode": "prompt"}
}, separators=(",", ":")))
PY
)"

openclaw mcp set "$SERVER_NAME" "$MCP_JSON"
openclaw mcp doctor "$SERVER_NAME" || true

echo "MATON_MCP=$SERVER_NAME"
echo 'MATON_MODE=REMOTE_OAUTH_READ_ONLY'
echo 'MATON_WRITE_TOOLS=EXCLUDED'
echo 'NEXT_MANUAL=openclaw mcp login maton-readonly'
echo 'After browser approval, verify with: openclaw mcp doctor maton-readonly --probe'
