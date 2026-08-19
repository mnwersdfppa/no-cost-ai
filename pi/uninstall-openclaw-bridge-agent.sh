#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
UNIT_DIR="$HOME/.config/systemd/user"

systemctl --user disable --now \
  openclaw-bridge-heartbeat.timer \
  openclaw-bridge-canonical-config.timer \
  openclaw-bridge-credential-readiness.timer \
  openclaw-bridge-command-status.timer 2>/dev/null || true

for unit in \
  openclaw-bridge-heartbeat.service \
  openclaw-bridge-heartbeat.timer \
  openclaw-bridge-canonical-config.service \
  openclaw-bridge-canonical-config.timer \
  openclaw-bridge-credential-readiness.service \
  openclaw-bridge-credential-readiness.timer \
  openclaw-bridge-command-status.service \
  openclaw-bridge-command-status.timer
 do
  rm -f "$UNIT_DIR/$unit"
 done

rm -f "$ROOT/bin/openclaw-bridge-agent"
systemctl --user daemon-reload

printf '%s\n' \
  'RESULT=OPENCLAW_SUPABASE_BRIDGE_AGENT_REMOVED' \
  'PI_AUTH_USER=UNCHANGED' \
  'PI_SESSION_FILE=RETAINED' \
  'SUPABASE_AUDIT_EVIDENCE=RETAINED' \
  'OPENCLAW_DATA=UNCHANGED' \
  'TELEGRAM_CONFIG=UNCHANGED' \
  'PROVIDER_CREDENTIALS=UNCHANGED'
