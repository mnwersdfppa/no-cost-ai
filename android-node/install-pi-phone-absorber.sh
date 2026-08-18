#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi 5 -> OpenClaw phone node/ADB absorber.
# Safe defaults:
# - no jailbreak/root
# - official OpenClaw mobile node is primary
# - USB ADB MCP is a local fallback
# - no arbitrary shell, reboot, delete, install/uninstall, SMS/call, purchase, or settings tools
# - status may auto-run; screen inspection and UI actions require approval

REPO_URL="${PHONE_ABSORBER_REPO_URL:-https://github.com/mnwersdfppa/no-cost-ai.git}"
REPO_REF="${PHONE_ABSORBER_REPO_REF:-feat/openclaw-android-node-absorber}"
INSTALL_ROOT="${PHONE_ABSORBER_ROOT:-$HOME/.openclaw/extensions/phone-absorber}"
MCP_DIR="$INSTALL_ROOT/android-node/adb-mcp"
LOG_DIR="$HOME/.openclaw/logs"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/phone-absorber-install-$STAMP.log"
exec > >(tee -a "$LOG_FILE") 2>&1

say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "PHASE=preflight"
if ! have openclaw; then
  say "RESULT=BLOCKED REASON=openclaw_not_found"
  exit 10
fi
if ! have git; then
  say "RESULT=BLOCKED REASON=git_not_found"
  exit 11
fi
if ! have node || ! have npm; then
  say "RESULT=BLOCKED REASON=node_or_npm_not_found"
  exit 12
fi

if ! have adb; then
  if have apt-get && have sudo; then
    say "Installing Android platform tools (adb only)..."
    sudo apt-get update -qq
    sudo apt-get install -y adb >/dev/null
  else
    say "RESULT=BLOCKED REASON=adb_not_found"
    exit 13
  fi
fi

say "PHASE=source"
if [[ -d "$INSTALL_ROOT/.git" ]]; then
  git -C "$INSTALL_ROOT" fetch --quiet origin "$REPO_REF"
  git -C "$INSTALL_ROOT" checkout --quiet "$REPO_REF"
  git -C "$INSTALL_ROOT" reset --hard --quiet "origin/$REPO_REF"
else
  rm -rf "$INSTALL_ROOT.tmp"
  git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_ROOT.tmp"
  mkdir -p "$(dirname "$INSTALL_ROOT")"
  rm -rf "$INSTALL_ROOT"
  mv "$INSTALL_ROOT.tmp" "$INSTALL_ROOT"
fi

say "PHASE=dependencies"
(
  cd "$MCP_DIR"
  npm install --omit=dev --no-audit --no-fund --silent
  npm run check --silent
)

say "PHASE=android_detection"
adb start-server >/dev/null 2>&1 || true
mapfile -t DEVICE_LINES < <(adb devices | awk 'NR>1 && NF>=2 {print $1" "$2}')
mapfile -t READY_SERIALS < <(printf '%s\n' "${DEVICE_LINES[@]:-}" | awk '$2=="device" {print $1}')
mapfile -t UNAUTH_SERIALS < <(printf '%s\n' "${DEVICE_LINES[@]:-}" | awk '$2=="unauthorized" {print $1}')

if (( ${#UNAUTH_SERIALS[@]} > 0 )); then
  say "ANDROID=UNAUTHORIZED"
  say "Unlock the phone and approve the USB debugging fingerprint; select Always allow only for this trusted Pi."
fi

if (( ${#READY_SERIALS[@]} == 0 )); then
  say "ANDROID=NOT_READY"
  say "Official mobile-node path is still available: install/open the official OpenClaw Android/iOS app and use the setup code printed below."
  openclaw qr --limited --setup-code-only || true
  say "RESULT=PARTIAL NEXT=approve_usb_debugging_or_pair_official_mobile_app"
  exit 20
fi

if (( ${#READY_SERIALS[@]} > 1 )); then
  say "RESULT=BLOCKED REASON=multiple_android_devices"
  printf 'SERIAL=%s\n' "${READY_SERIALS[@]}"
  exit 21
fi

SERIAL="${READY_SERIALS[0]}"
MODEL="$(adb -s "$SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r' | head -n1)"
ANDROID_VERSION="$(adb -s "$SERIAL" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' | head -n1)"
say "ANDROID=READY SERIAL=$SERIAL MODEL=$MODEL VERSION=$ANDROID_VERSION"

say "PHASE=openclaw_mcp_registration"
SERVER="$MCP_DIR/server.mjs"
COMMON="{\"command\":\"node\",\"args\":[\"$SERVER\"],\"env\":{\"ANDROID_SERIAL\":\"$SERIAL\",\"ADB_BIN\":\"$(command -v adb)\"},\"requestTimeoutMs\":30000,\"connectionTimeoutMs\":10000}"

# Fast, read-only status lane.
openclaw mcp set android-phone-status "$(python3 - "$COMMON" <<'PY'
import json,sys
x=json.loads(sys.argv[1]); x['env']['PHONE_WRITE_ENABLED']='0'; x['toolFilter']={'include':['phone_status']}; x['codex']={'defaultToolsApprovalMode':'auto'}; print(json.dumps(x,separators=(',',':')))
PY
)"

# Sensitive inspection lane; approval prompt required.
openclaw mcp set android-phone-inspect "$(python3 - "$COMMON" <<'PY'
import json,sys
x=json.loads(sys.argv[1]); x['env']['PHONE_WRITE_ENABLED']='0'; x['toolFilter']={'include':['phone_screenshot','phone_ui_dump']}; x['codex']={'defaultToolsApprovalMode':'prompt'}; print(json.dumps(x,separators=(',',':')))
PY
)"

# Narrow, allowlisted action lane; every call requires approval.
openclaw mcp set android-phone-actions "$(python3 - "$COMMON" <<'PY'
import json,sys
x=json.loads(sys.argv[1]); x['env']['PHONE_WRITE_ENABLED']='1'; x['env']['PHONE_ALLOWED_PACKAGES']='ai.openclaw.app,com.termux,org.telegram.messenger,com.android.chrome'; x['toolFilter']={'include':['phone_open_app','phone_launch_url','phone_key','phone_tap','phone_swipe','phone_type_text']}; x['codex']={'defaultToolsApprovalMode':'prompt'}; print(json.dumps(x,separators=(',',':')))
PY
)"

say "PHASE=probe"
openclaw mcp doctor android-phone-status --probe
openclaw mcp doctor android-phone-inspect --probe
openclaw mcp doctor android-phone-actions --probe
openclaw mcp status --verbose || true

say "PHASE=official_mobile_node"
# Limited operator access omits admin while retaining the node capability lane.
SETUP_CODE="$(openclaw qr --limited --setup-code-only 2>/dev/null || true)"
if [[ -n "$SETUP_CODE" ]]; then
  say "OPENCLAW_MOBILE_SETUP_CODE=$SETUP_CODE"
  say "Paste this short-lived setup code into the official OpenClaw mobile app."
fi

say "PHASE=gateway_refresh"
openclaw mcp reload || true
openclaw gateway restart --safe 2>/dev/null || openclaw gateway restart 2>/dev/null || true
openclaw nodes status || true

say "RESULT=PREPARED_VERIFIED"
say "PRIMARY=official_openclaw_mobile_node"
say "FALLBACK=usb_adb_allowlisted_mcp"
say "JAILBREAK_ROOT=NOT_REQUIRED"
say "TELEGRAM_POLLER=UNCHANGED_SINGLE_GATEWAY"
say "WRITE_POLICY=APPROVAL_REQUIRED"
say "ROLLBACK=$INSTALL_ROOT/android-node/rollback-pi-phone-absorber.sh"
say "LOG=$LOG_FILE"
