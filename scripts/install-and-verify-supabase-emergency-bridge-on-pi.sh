#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-supabase-emergency-bridge-on-pi.sh"
CANONICAL_VERIFY="$SCRIPT_DIR/verify-canonical-config-on-pi.py"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$HOME/.openclaw/secrets/pi-work-queue.env}"

rollback_timers() {
  systemctl --user disable --now \
    openclaw-emergency-heartbeat.timer \
    openclaw-credential-readiness.timer \
    >/dev/null 2>&1 || true
}

[[ -r "$INSTALLER" ]] || {
  echo "BLOCKED=INSTALLER_MISSING:$INSTALLER" >&2
  exit 20
}
[[ -r "$CANONICAL_VERIFY" ]] || {
  echo "BLOCKED=CANONICAL_VERIFIER_MISSING:$CANONICAL_VERIFY" >&2
  exit 21
}
[[ -r "$ENV_FILE" ]] || {
  echo "BLOCKED=PI_ENV_FILE_MISSING:$ENV_FILE" >&2
  exit 22
}

chmod 700 "$INSTALLER" "$CANONICAL_VERIFY"

bash "$INSTALLER"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if ! python3 "$CANONICAL_VERIFY"; then
  rollback_timers
  echo 'RESULT=ROLLED_BACK_AFTER_CANONICAL_CONFIG_FAILURE' >&2
  exit 23
fi

# Re-run the bounded heartbeat after canonical configuration passes so both Pi
# cloud gates have fresh evidence from the same activation session.
if ! "$HOME/.openclaw/bin/openclaw-emergency-bridge" heartbeat; then
  rollback_timers
  echo 'RESULT=ROLLED_BACK_AFTER_HEARTBEAT_FAILURE' >&2
  exit 24
fi

printf '%s\n' \
  'RESULT=SUPABASE_EMERGENCY_BRIDGE_PI_E2E_READY' \
  'PI_AUTHENTICATED_STATUS=PASS' \
  'PI_HEARTBEAT=PASS' \
  'CANONICAL_CONFIG_PI_E2E=PASS' \
  'PAID_API_FALLBACK=OFF' \
  'PUBLIC_SHELL=OFF' \
  'SECOND_TELEGRAM_POLLER=OFF' \
  'NEXT=run secure phone T3, existing Telegram T4, and verified rollback'
