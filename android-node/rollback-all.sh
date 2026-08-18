#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/disable-channel-relay.sh" || true
rm -f "$HOME/.config/systemd/user/openclaw-phone-relay.service"
systemctl --user daemon-reload || true
"$SCRIPT_DIR/rollback-pi-bridge.sh"
echo "RESULT=ANDROID_ABSORBER_ROLLED_BACK"
