#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
BIN="$HOME/.openclaw/bin"
LOGS="$ROOT/logs"
ENV_FILE="$SECRETS/phone-bridge.env"
SSH_KEY="$SECRETS/phone_ssh_ed25519"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-0}"
AUTO_TYPE_TERMUX="${AUTO_TYPE_TERMUX:-0}"

mkdir -p "$ROOT" "$SECRETS" "$BIN" "$LOGS"
chmod 700 "$ROOT" "$SECRETS" "$BIN" "$LOGS"

need=()
for cmd in adb node npm ssh ssh-keygen python3 openclaw; do
  command -v "$cmd" >/dev/null 2>&1 || need+=("$cmd")
done

if ((${#need[@]} > 0)) && [[ "$INSTALL_PACKAGES" == "1" ]] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y android-tools-adb nodejs npm openssh-client python3
  need=()
  for cmd in adb node npm ssh ssh-keygen python3 openclaw; do
    command -v "$cmd" >/dev/null 2>&1 || need+=("$cmd")
  done
fi

if ((${#need[@]} > 0)); then
  printf 'BLOCKED=MISSING_COMMANDS:%s\n' "$(IFS=,; echo "${need[*]}")"
  echo "NEXT=rerun with INSTALL_PACKAGES=1 or install the listed commands"
  exit 20
fi

adb start-server >/dev/null
mapfile -t READY < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
mapfile -t UNAUTHORIZED < <(adb devices | awk 'NR>1 && $2=="unauthorized" {print $1}')
if ((${#READY[@]} == 0)); then
  if ((${#UNAUTHORIZED[@]} > 0)); then
    echo "BLOCKED=ADB_UNAUTHORIZED"
    echo "NEXT=unlock the phone and approve the USB debugging fingerprint"
  else
    echo "BLOCKED=NO_ANDROID_DEVICE"
    echo "NEXT=connect the Android phone by USB and enable USB debugging"
  fi
  exit 21
fi
if ((${#READY[@]} > 1)) && [[ -z "${ANDROID_SERIAL:-}" ]]; then
  printf 'BLOCKED=MULTIPLE_ANDROID_DEVICES:%s\n' "$(IFS=,; echo "${READY[*]}")"
  echo "NEXT=set ANDROID_SERIAL to the intended phone"
  exit 22
fi
SERIAL="${ANDROID_SERIAL:-${READY[0]}}"
export ANDROID_SERIAL="$SERIAL"

MODEL="$(adb -s "$SERIAL" shell getprop ro.product.model | tr -d '\r')"
ANDROID_VERSION="$(adb -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r')"

if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C 'openclaw-pi-phone-bridge' -f "$SSH_KEY"
fi
chmod 600 "$SSH_KEY"
chmod 644 "$SSH_KEY.pub"

adb -s "$SERIAL" push "$SSH_KEY.pub" /sdcard/Download/openclaw_pi.pub >/dev/null
adb -s "$SERIAL" push "$SCRIPT_DIR/phone-termux-bootstrap.sh" /sdcard/Download/openclaw-phone-bootstrap.sh >/dev/null
adb -s "$SERIAL" forward tcp:8022 tcp:8022 >/dev/null

rm -rf "$ROOT/adb-mcp" "$ROOT/codex-phone-mcp"
cp -a "$SCRIPT_DIR/adb-mcp" "$ROOT/adb-mcp"
cp -a "$SCRIPT_DIR/codex-phone-mcp" "$ROOT/codex-phone-mcp"
(
  cd "$ROOT/adb-mcp"
  npm install --omit=dev --no-audit --no-fund
  npm run check
)
(
  cd "$ROOT/codex-phone-mcp"
  npm install --omit=dev --no-audit --no-fund
  npm run check
)

TERMUX_UID="$(adb -s "$SERIAL" shell dumpsys package com.termux 2>/dev/null | sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' | head -n1 | tr -d '\r')"
PHONE_SSH_USER="${PHONE_SSH_USER:-}"
if [[ -z "$PHONE_SSH_USER" && "$TERMUX_UID" =~ ^[0-9]+$ && "$TERMUX_UID" -ge 10000 ]]; then
  PHONE_SSH_USER="u0_a$((TERMUX_UID - 10000))"
fi

cat > "$ENV_FILE" <<ENV
ANDROID_SERIAL=$SERIAL
PHONE_ALLOWED_PACKAGES=ai.openclaw.app,com.termux,org.telegram.messenger,com.android.chrome
PHONE_SSH_HOST=127.0.0.1
PHONE_SSH_PORT=8022
PHONE_SSH_USER=$PHONE_SSH_USER
PHONE_SSH_KEY=$SSH_KEY
PHONE_CODEX_MODEL=gpt-5.6-sol
PHONE_CODEX_ENABLED=0
PHONE_WRITE_ENABLED=0
PHONE_CODEX_TIMEOUT_MS=240000
ENV
chmod 600 "$ENV_FILE"

cat > "$BIN/android-phone-read-mcp" <<LAUNCH
#!/usr/bin/env bash
set -euo pipefail
set -a
source "$ENV_FILE"
set +a
export PHONE_WRITE_ENABLED=0
exec node "$ROOT/adb-mcp/server.mjs"
LAUNCH
cat > "$BIN/android-phone-write-mcp" <<LAUNCH
#!/usr/bin/env bash
set -euo pipefail
set -a
source "$ENV_FILE"
set +a
export PHONE_WRITE_ENABLED=1
exec node "$ROOT/adb-mcp/server.mjs"
LAUNCH
cat > "$BIN/phone-codex-mcp" <<LAUNCH
#!/usr/bin/env bash
set -euo pipefail
set -a
source "$ENV_FILE"
set +a
exec node "$ROOT/codex-phone-mcp/server.mjs"
LAUNCH
chmod 700 "$BIN/android-phone-read-mcp" "$BIN/android-phone-write-mcp" "$BIN/phone-codex-mcp"

python3 - "$BIN" <<'PY' > "$ROOT/mcp.android-phone-read.json"
import json,sys
b=sys.argv[1]
print(json.dumps({
  "command": f"{b}/android-phone-read-mcp",
  "enabled": True,
  "requestTimeoutMs": 30000,
  "connectionTimeoutMs": 10000,
  "toolFilter": {"include": ["phone_status","phone_screenshot","phone_ui_dump"]},
  "codex": {"defaultToolsApprovalMode": "auto"}
}))
PY
python3 - "$BIN" <<'PY' > "$ROOT/mcp.android-phone-write.json"
import json,sys
b=sys.argv[1]
print(json.dumps({
  "command": f"{b}/android-phone-write-mcp",
  "enabled": False,
  "requestTimeoutMs": 30000,
  "connectionTimeoutMs": 10000,
  "toolFilter": {"include": ["phone_open_app","phone_launch_url","phone_key","phone_tap","phone_swipe","phone_type_text"]},
  "codex": {"defaultToolsApprovalMode": "approve"}
}))
PY
python3 - "$BIN" <<'PY' > "$ROOT/mcp.phone-codex.json"
import json,sys
b=sys.argv[1]
print(json.dumps({
  "command": f"{b}/phone-codex-mcp",
  "enabled": True,
  "requestTimeoutMs": 260000,
  "connectionTimeoutMs": 15000,
  "toolFilter": {"include": ["phone_codex_status","phone_codex_ask"]},
  "codex": {"defaultToolsApprovalMode": "auto"}
}))
PY

openclaw mcp set android-phone-read "$(cat "$ROOT/mcp.android-phone-read.json")"
openclaw mcp set android-phone-write "$(cat "$ROOT/mcp.android-phone-write.json")"
openclaw mcp set phone-codex "$(cat "$ROOT/mcp.phone-codex.json")"
openclaw mcp doctor android-phone-read --probe
openclaw mcp doctor phone-codex --probe

cat > "$LOGS/install-receipt.json" <<JSON
{
  "result": "prepared",
  "android_serial": "$SERIAL",
  "phone_model": "$MODEL",
  "android_version": "$ANDROID_VERSION",
  "termux_user_detected": "$PHONE_SSH_USER",
  "adb_forward": "127.0.0.1:8022 -> phone:8022",
  "mcp_read": "enabled",
  "mcp_write": "disabled",
  "phone_codex": "registered_disabled_at_tool_level",
  "paid_api_fallback": "unchanged",
  "secrets_embedded": false
}
JSON
chmod 600 "$LOGS/install-receipt.json"

adb -s "$SERIAL" shell am start -n com.termux/.app.TermuxActivity >/dev/null 2>&1 || true
if [[ "$AUTO_TYPE_TERMUX" == "1" ]]; then
  sleep 2
  adb -s "$SERIAL" shell input text 'bash%s/sdcard/Download/openclaw-phone-bootstrap.sh'
  adb -s "$SERIAL" shell input keyevent 66
fi

if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
  openclaw gateway restart --safe || true
else
  openclaw gateway restart || true
fi

printf 'RESULT=PI_BRIDGE_PREPARED\n'
printf 'PHONE=%s Android=%s Serial=%s\n' "$MODEL" "$ANDROID_VERSION" "$SERIAL"
printf 'NEXT_ON_PHONE=bash /sdcard/Download/openclaw-phone-bootstrap.sh\n'
printf 'AFTER_PHONE=run %s/verify-phone-bridge.sh\n' "$SCRIPT_DIR"
