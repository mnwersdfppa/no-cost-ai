#!/usr/bin/env bash
set -euo pipefail

SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"

[[ -r "$ENV_FILE" ]] || { echo 'BLOCKED=PHONE_BRIDGE_ENV_MISSING'; exit 121; }
for command in adb ssh-keyscan ssh-keygen python3; do
  command -v "$command" >/dev/null 2>&1 || { echo "BLOCKED=MISSING_COMMAND:$command"; exit 122; }
done

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for variable in ANDROID_SERIAL PHONE_SSH_HOST PHONE_SSH_PORT PHONE_SSH_KNOWN_HOSTS PHONE_SSH_HOST_KEY_SHA256; do
  [[ -n "${!variable:-}" ]] || { echo "BLOCKED=MISSING_ENV:$variable"; exit 123; }
done
[[ "$PHONE_SSH_HOST_KEY_SHA256" == SHA256:* ]] || { echo 'BLOCKED=OPERATOR_VERIFIED_SSH_FINGERPRINT_REQUIRED'; exit 124; }

adb start-server >/dev/null
[[ "$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)" == device ]] || { echo 'BLOCKED=ADB_DEVICE_NOT_READY'; exit 125; }
adb -s "$ANDROID_SERIAL" forward --remove tcp:"$PHONE_SSH_PORT" >/dev/null 2>&1 || true
adb -s "$ANDROID_SERIAL" forward tcp:"$PHONE_SSH_PORT" tcp:8022 >/dev/null

mkdir -p "$(dirname "$PHONE_SSH_KNOWN_HOSTS")"
chmod 700 "$(dirname "$PHONE_SSH_KNOWN_HOSTS")"

TMP_SCAN="$(mktemp)"
TMP_RECORD="$(mktemp "$(dirname "$PHONE_SSH_KNOWN_HOSTS")/.phone-known-host.XXXXXX")"
cleanup() { rm -f "$TMP_SCAN" "$TMP_RECORD"; }
trap cleanup EXIT

if ! ssh-keyscan -T 10 -t ed25519 -p "$PHONE_SSH_PORT" "$PHONE_SSH_HOST" > "$TMP_SCAN" 2>/dev/null; then
  echo 'BLOCKED=PHONE_SSHD_NOT_REACHABLE'
  exit 126
fi

python3 - "$TMP_SCAN" "$TMP_RECORD" "$PHONE_SSH_HOST_KEY_SHA256" <<'PY'
import os
import subprocess
import sys

source, destination, expected = sys.argv[1:]
lines = [
    line.strip()
    for line in open(source, encoding="utf-8", errors="strict")
    if line.strip() and not line.lstrip().startswith("#")
]
if len(lines) != 1:
    raise SystemExit("BLOCKED=SCANNED_SSH_HOST_KEY_RECORD_COUNT_INVALID")
parts = lines[0].split()
if len(parts) != 3 or parts[1] != "ssh-ed25519":
    raise SystemExit("BLOCKED=SCANNED_SSH_HOST_KEY_FORMAT_INVALID")
with open(destination, "w", encoding="utf-8") as handle:
    handle.write(lines[0] + "\n")
os.chmod(destination, 0o600)
probe = subprocess.run(
    ["ssh-keygen", "-lf", destination, "-E", "sha256"],
    capture_output=True,
    text=True,
    check=False,
)
rows = [row for row in probe.stdout.splitlines() if row.strip()]
if probe.returncode != 0 or len(rows) != 1:
    raise SystemExit("BLOCKED=SCANNED_SSH_HOST_KEY_PARSE_INVALID")
fields = rows[0].split()
if len(fields) < 2 or fields[1] != expected or "(ED25519)" not in rows[0]:
    raise SystemExit("BLOCKED=SCANNED_SSH_HOST_KEY_FINGERPRINT_MISMATCH")
PY

if [[ -s "$PHONE_SSH_KNOWN_HOSTS" ]]; then
  cmp -s "$TMP_RECORD" "$PHONE_SSH_KNOWN_HOSTS" || {
    echo 'BLOCKED=PINNED_SSH_HOST_KEY_CHANGED'
    exit 127
  }
  echo 'PHONE_SSH_HOST_KEY=EXISTING_PIN_VERIFIED'
else
  chmod 600 "$TMP_RECORD"
  mv -f "$TMP_RECORD" "$PHONE_SSH_KNOWN_HOSTS"
  chmod 600 "$PHONE_SSH_KNOWN_HOSTS"
  echo 'PHONE_SSH_HOST_KEY=FIRST_PIN_ATOMICALLY_WRITTEN'
fi

echo "PHONE_SSH_HOST_KEY_SHA256=$PHONE_SSH_HOST_KEY_SHA256"
