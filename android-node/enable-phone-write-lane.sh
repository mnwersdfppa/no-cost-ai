#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="$ROOT_DIR/adb-mcp"
MCP_SERVER="$MCP_DIR/server.mjs"

command -v openclaw >/dev/null 2>&1 || { echo 'ERROR: openclaw is required' >&2; exit 1; }
command -v adb >/dev/null 2>&1 || { echo 'ERROR: adb is required' >&2; exit 1; }

mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
[[ ${#DEVICES[@]} -eq 1 ]] || { echo "ERROR: expected exactly one authorized Android device; found ${#DEVICES[@]}" >&2; exit 1; }
SERIAL="${DEVICES[0]}"

MCP_JSON="$(python3 - "$MCP_SERVER" "$MCP_DIR" "$SERIAL" <<'PY'
import json, sys
server, cwd, serial = sys.argv[1:]
print(json.dumps({
  "command": "node",
  "args": [server],
  "cwd": cwd,
  "env": {
    "ANDROID_SERIAL": serial,
    "PHONE_WRITE_ENABLED": "1",
    "PHONE_ALLOWED_PACKAGES": "ai.openclaw.app,com.termux,org.telegram.messenger,com.android.chrome"
  },
  "enabled": True,
  "connectionTimeoutMs": 10000,
  "requestTimeoutMs": 30000,
  "supportsParallelToolCalls": False,
  "toolFilter": {
    "include": [
      "phone_status",
      "phone_screenshot",
      "phone_ui_dump",
      "phone_open_app",
      "phone_launch_url",
      "phone_key",
      "phone_tap",
      "phone_swipe",
      "phone_type_text"
    ]
  },
  "codex": {"defaultToolsApprovalMode": "prompt"}
}, separators=(",", ":")))
PY
)"

openclaw mcp set android-safe "$MCP_JSON"
openclaw mcp doctor android-safe --probe
openclaw mcp reload || true

echo 'PHONE_WRITE_LANE=ENABLED_ALLOWLIST_ONLY'
echo 'Arbitrary adb shell, installs, uninstalls, calls, purchases, account changes and security-setting changes remain unavailable.'
