#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="$ROOT_DIR/adb-mcp"
MCP_SERVER="$MCP_DIR/server.mjs"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-0}"
INSTALL_SCRCPY="${INSTALL_SCRCPY:-0}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required"; }

printf '== OpenClaw Android node installer: read-only first ==\n'
need openclaw
need node
need npm
need python3

NODE_VERSION="$(node -p 'process.versions.node')"
NODE_MAJOR="${NODE_VERSION%%.*}"
[[ "$NODE_MAJOR" -ge 22 ]] || fail "Node.js 22+ is required; found v$NODE_VERSION"

if ! command -v adb >/dev/null 2>&1; then
  if [[ "$INSTALL_PACKAGES" == "1" ]] && command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    printf 'Installing Android platform tools by explicit opt-in...\n'
    sudo apt-get update
    sudo apt-get install -y adb
  else
    fail 'adb is missing; install it or rerun with INSTALL_PACKAGES=1'
  fi
fi

if [[ "$INSTALL_SCRCPY" == "1" ]] && ! command -v scrcpy >/dev/null 2>&1; then
  if command -v apt-cache >/dev/null 2>&1 && apt-cache show scrcpy >/dev/null 2>&1; then
    sudo apt-get install -y scrcpy
  else
    fail 'scrcpy was requested but is unavailable from this package source'
  fi
fi

adb start-server >/dev/null
mapfile -t AUTHORIZED < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
mapfile -t UNAUTHORIZED < <(adb devices | awk 'NR>1 && $2=="unauthorized" {print $1}')

if (( ${#UNAUTHORIZED[@]} > 0 )); then
  printf 'BLOCKED=ADB_UNAUTHORIZED:%s\n' "${UNAUTHORIZED[*]}" >&2
  printf 'NEXT=unlock the phone and approve the USB debugging fingerprint\n' >&2
  exit 20
fi
(( ${#AUTHORIZED[@]} == 1 )) || fail "Expected exactly one authorized Android device; found ${#AUTHORIZED[@]}"
SERIAL="${AUTHORIZED[0]}"
printf 'Android device: %s\n' "$SERIAL"

[[ -s "$MCP_DIR/package-lock.json" ]] || fail 'Reviewed package-lock.json is required'
printf 'Installing locked local MCP dependencies...\n'
(
  cd "$MCP_DIR"
  npm ci --ignore-scripts --no-audit --no-fund
  node --check "$MCP_SERVER"
)

MCP_JSON="$(python3 - "$MCP_SERVER" "$MCP_DIR" "$SERIAL" <<'PY'
import json, sys
server, cwd, serial = sys.argv[1:]
print(json.dumps({
  "command": "node",
  "args": [server],
  "cwd": cwd,
  "env": {
    "ANDROID_SERIAL": serial,
    "PHONE_WRITE_ENABLED": "0"
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
printf 'Open the official OpenClaw Android app and enter this short-lived setup code:\n'
openclaw qr --limited --setup-code-only || {
  printf 'BLOCKED=SETUP_CODE_UNAVAILABLE\n' >&2
  printf 'NEXT=openclaw gateway status\n' >&2
}

printf '\n== Verification ==\n'
openclaw mcp status --verbose || true
openclaw nodes status || true
openclaw devices list || true

printf '\nREADY_READ_ONLY=1\n'
printf 'PAID_API_FALLBACK=UNCHANGED\n'
printf 'TELEGRAM_POLLER=UNCHANGED\n'
printf 'Optional task-scoped write lane: %s/enable-phone-write-lane.sh\n' "$ROOT_DIR"
