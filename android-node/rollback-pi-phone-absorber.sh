#!/usr/bin/env bash
set -euo pipefail

# Reversible rollback. This removes only OpenClaw MCP registrations created by
# install-pi-phone-absorber.sh. It does not delete phone data, pairings, apps,
# credentials, repository files, or existing OpenClaw/Telegram configuration.

for name in android-phone-status android-phone-inspect android-phone-actions; do
  openclaw mcp unset "$name" 2>/dev/null || true
done
openclaw mcp reload 2>/dev/null || true
openclaw gateway restart --safe 2>/dev/null || openclaw gateway restart 2>/dev/null || true
printf '%s\n' \
  'RESULT=ROLLED_BACK' \
  'REMOVED_MCP=android-phone-status,android-phone-inspect,android-phone-actions' \
  'PHONE_DATA=UNCHANGED' \
  'OPENCLAW_PAIRING=UNCHANGED' \
  'TELEGRAM=UNCHANGED'
