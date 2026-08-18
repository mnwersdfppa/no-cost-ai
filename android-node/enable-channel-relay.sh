#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
[[ -r "$ENV_FILE" ]] || { echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING"; exit 90; }

RUN_LLM_TEST=1 ENABLE_AFTER_VERIFY=1 "$SCRIPT_DIR/verify-phone-bridge.sh"
if grep -q '^PHONE_RELAY_ENABLED=' "$ENV_FILE"; then
  sed -i 's/^PHONE_RELAY_ENABLED=.*/PHONE_RELAY_ENABLED=1/' "$ENV_FILE"
else
  printf '%s\n' 'PHONE_RELAY_ENABLED=1' >> "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

systemctl --user daemon-reload
systemctl --user enable --now openclaw-phone-relay.service
sleep 2
systemctl --user --no-pager --full status openclaw-phone-relay.service || true

echo "RESULT=CHANNEL_RELAY_ENABLED"
echo "TELEGRAM_TEST=send one normal direct message to the existing OpenClaw bot"
echo "NO_SECOND_POLLER=true"
