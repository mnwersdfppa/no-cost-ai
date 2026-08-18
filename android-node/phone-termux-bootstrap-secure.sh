#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

DOWNLOADS="${OPENCLAW_PHONE_DOWNLOADS:-/sdcard/Download}"
INSTALLER="$DOWNLOADS/openclaw-install-codex-verified.sh"
CORE="$DOWNLOADS/openclaw-phone-bootstrap-core.sh"
PUB="$DOWNLOADS/openclaw_pi.pub"

for file in "$INSTALLER" "$CORE" "$PUB"; do
  if [[ ! -r "$file" ]]; then
    echo "BLOCKED=REQUIRED_PHONE_BOOTSTRAP_FILE_MISSING"
    echo "FILE=$file"
    exit 81
  fi
done

chmod 700 "$INSTALLER" "$CORE" 2>/dev/null || true
PHONE_CODEX_VERSION="${PHONE_CODEX_VERSION:-0.146.0}" INSTALL_CODEX="${INSTALL_CODEX:-1}" bash "$INSTALLER"

python - "$PUB" <<'PY'
import base64,re,sys
path=sys.argv[1]
lines=[line.strip() for line in open(path,encoding='utf-8',errors='strict') if line.strip()]
if len(lines)!=1:
    raise SystemExit('BLOCKED=PI_PUBLIC_KEY_RECORD_COUNT_INVALID')
parts=lines[0].split()
if len(parts) not in (2,3) or parts[0] != 'ssh-ed25519':
    raise SystemExit('BLOCKED=PI_PUBLIC_KEY_FORMAT_INVALID')
if len(parts)==3 and parts[2] != 'openclaw-pi-phone-bridge':
    raise SystemExit('BLOCKED=PI_PUBLIC_KEY_COMMENT_INVALID')
try:
    decoded=base64.b64decode(parts[1],validate=True)
except Exception:
    raise SystemExit('BLOCKED=PI_PUBLIC_KEY_BASE64_INVALID')
if len(decoded) < 40:
    raise SystemExit('BLOCKED=PI_PUBLIC_KEY_LENGTH_INVALID')
print('PI_PUBLIC_KEY=ONE_ED25519_RECORD_VERIFIED')
PY

export INSTALL_CODEX=0
export PHONE_CODEX_VERSION="${PHONE_CODEX_VERSION:-0.146.0}"
exec bash "$CORE"
