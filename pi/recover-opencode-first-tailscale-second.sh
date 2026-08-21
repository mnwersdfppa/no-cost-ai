#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Compatibility entrypoint for the Supabase-first recovery path.
# The OpenCode provider key remains in Supabase Edge. This wrapper downloads
# only the reviewed installer, verifies its exact digest, and then executes it.
INSTALLER_URL="https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-recovery-installer-verified"
INSTALLER_SHA256="4c21d9eab6fff335950f8a4c8c7a064a20b9aa00aead487b811cee779e8ae947"
RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-$HOME/.openclaw/runtime}"
TMP_FILE=""

log() { printf '%s\n' "$*"; }
fail() { log "RESULT=BLOCKED"; log "BLOCKER=$1"; exit "${2:-1}"; }
cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f -- "$TMP_FILE" 2>/dev/null || true
  fi
}
trap cleanup EXIT

for command in curl sha256sum bash mktemp; do
  command -v "$command" >/dev/null 2>&1 || fail "MISSING_COMMAND:$command" 20
done

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
TMP_FILE="$(mktemp "$RUNTIME_DIR/.pi-recovery-installer.XXXXXX")"
chmod 600 "$TMP_FILE"

curl --fail --silent --show-error --location \
  --proto '=https' --tlsv1.2 \
  --connect-timeout 10 --max-time 45 \
  -H 'cache-control: no-cache' \
  -H 'user-agent: openclaw-pi-recovery-wrapper/3' \
  "$INSTALLER_URL" > "$TMP_FILE"

printf '%s  %s\n' "$INSTALLER_SHA256" "$TMP_FILE" | sha256sum --check --status \
  || fail "INSTALLER_SHA256_MISMATCH" 21

head -n 1 "$TMP_FILE" | grep -Fqx '#!/usr/bin/env bash' \
  || fail "INSTALLER_SHEBANG_INVALID" 22

grep -Fq 'PI_REFRESH_TOKEN' "$TMP_FILE" \
  || fail "INSTALLER_REFRESH_CONTRACT_MISSING" 23
grep -Fq 'agents.defaults.model' "$TMP_FILE" \
  || fail "INSTALLER_MODEL_REPAIR_CONTRACT_MISSING" 24
grep -Fq 'provider_secret_returned' "$TMP_FILE" \
  || fail "INSTALLER_SECRET_BOUNDARY_RECEIPT_MISSING" 25
if grep -Eq 'OPENCODE_API_KEY=|TAILSCALE_AUTHKEY=' "$TMP_FILE"; then
  fail "INSTALLER_CONTAINS_LEGACY_PROVIDER_SECRET_EXPORT" 26
fi

log "INSTALLER_SHA256_VERIFIED=$INSTALLER_SHA256"
log "RECOVERY_MODE=SUPABASE_GUARDIAN_SCOPED_PI_JWT"
log "SECOND_TELEGRAM_POLLER=false"
log "PAID_API_FALLBACK=false"

bash "$TMP_FILE" "$@"
