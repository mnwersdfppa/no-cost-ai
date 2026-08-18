#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="$ROOT_DIR/adb-mcp"
MCP_SERVER="$MCP_DIR/server.mjs"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required"; }

printf '== OpenClaw Android node installer ==\n'
need openclaw
need node
need npm

NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
[[ "$NODE_MAJOR" -ge 20 ]] || fail "Node.js 20+ is required; found $(node -v)"

if ! command -v adb >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    printf 'Installing Android platform tools...\n'
    sudo apt-get update
    sudo apt-get install -y adb
  else
    fail 'adb is missing and could not be installed automatically'
  fi
fi

# scrcpy is optional. Install only when the distro provides it.
if ! command -v scrcpy >/dev/null 2>&1 && command -v apt-cache >/dev/null 2>&1 && apt-cache show scrcpy >/dev/null 2>&1; then
  sudo apt-get install -y scrcpy || true
fi

adb start-server >/dev/null
mapfile -t AUTHORIZED < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
mapfile -t UNAUTHORIZED < <(adb devices | awk 'NR>1 && $2=="unauthorized" {print $1}')

if (( ${#UNAUTHORIZED[@]} > 0 )); then
  printf 'Android authorization is pending on: %s\n' "${UNAUTHORIZED[*]}" >&2
  printf 'Unlock the phone, approve the USB debugging fingerprint, then rerun this script.\n' >&2
  exit 20
fi

(( ${#AUTHORIZED[@]} == 1 )) || fail "Expected exactly one authorized Android device; found ${#AUTHORIZED[@]}"
SERIAL="${AUTHORIZED[0]}"
printf 'Android device: %s\n' "$SERIAL"

printf 'Installing local MCP dependencies...\n'
cd "$MCP_DIR"
npm install --ignore-scripts --no-audit --no-fund
node --check "$MCP_SERVER"

MCP_JSON="$(python3 - "$MCP_SERVER" "$MCP_DIR" "$SERIAL" <<'PY'
import json, sys
server, cwd, serial = sys.argv[1:]
print(json.dumps({
  "command": "node",
  "args": [server],
  "cwd": cwd,
  "env": {
    "ANDROID_SERIAL": serial,
    "PHONE_WRITE_ENABLED": "0",
    "PHONE_ALLOWED_PACKAGES": "ai.openclaw.app,com.termux,org.telegram.messenger,com.android.chrome"
  },
  "enabled": True,
  "connectionTimeoutMs": 10000,
  "requestTimeoutMs": 30000,
  "supportsParallelToolCalls": False,
  "toolFilter": {
    "include": ["phone_status", "phone_screenshot", "phone_ui_dump"]
  },
  "codex": {"defaultToolsApprovalMode": "prompt"}
}, separators=(",", ":")))
PY
)"

printf 'Registering read-only Android MCP tools...\n'
openclaw mcp set android-safe "$MCP_JSON"
openclaw mcp doctor android-safe --probe
openclaw mcp reload || true

printf '\n== Official Android OpenClaw pairing ==\n'
printf 'Install/open the official OpenClaw Android app, then enter this short-lived setup code:\n'
openclaw qr --limited --setup-code-only || {
  printf 'Could not generate a setup code. Check the Gateway with: openclaw gateway status\n' >&2
}

printf '\n== Verification ==\n'
openclaw mcp status --verbose || true
openclaw nodes status || true
openclaw devices list || true

printf '\nREADY_READ_ONLY=1\n'
printf 'Telegram test: Check the connected phone status. Do not change anything.\n'
printf 'Optional write lane: %s/enable-phone-write-lane.sh\n' "$ROOT_DIR"
