#!/usr/bin/env bash
set -euo pipefail

SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
if [[ -r "$ENV_FILE" ]]; then
  if grep -q '^PHONE_RELAY_ENABLED=' "$ENV_FILE"; then
    sed -i 's/^PHONE_RELAY_ENABLED=.*/PHONE_RELAY_ENABLED=0/' "$ENV_FILE"
  else
    printf '%s\n' 'PHONE_RELAY_ENABLED=0' >> "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
fi
systemctl --user disable --now openclaw-phone-relay.service >/dev/null 2>&1 || true
echo "RESULT=CHANNEL_RELAY_DISABLED"
