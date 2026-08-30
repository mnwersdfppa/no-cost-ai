#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

MODEL_INSTALLER_URL="https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-recovery-installer-verified"
MODEL_INSTALLER_SHA256="4c21d9eab6fff335950f8a4c8c7a064a20b9aa00aead487b811cee779e8ae947"
WORKER_INSTALLER_URL="https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-recovery-worker-installer-verified"
WORKER_INSTALLER_SHA256="cfa9b13c12c5937c9d0156b9279d5834ffc267986b38d51e38dd0eaac1c87c22"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-$OPENCLAW_HOME/runtime}"
SECRETS_FILE="${OPENCLAW_PI_ENV_FILE:-$OPENCLAW_HOME/secrets/pi-work-queue.env}"
RECEIPT_FILE="$RUNTIME_DIR/guardian-master-install-receipt.json"
TMP_DIR=""

log() { printf '%s\n' "$*"; }
fail() {
  local code="$1"
  local status="${2:-1}"
  log "RESULT=BLOCKED"
  log "BLOCKER=$code"
  exit "$status"
}
cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

for command in curl sha256sum bash mktemp date grep head chmod mkdir mv; do
  command -v "$command" >/dev/null 2>&1 || fail "MISSING_COMMAND:$command" 20
done

[[ -f "$SECRETS_FILE" ]] || fail "PI_REFRESH_ENV_MISSING:$SECRETS_FILE" 21
chmod 600 "$SECRETS_FILE" 2>/dev/null || true
grep -Eq '^PI_REFRESH_TOKEN=.{20,}$' "$SECRETS_FILE" \
  || fail "PI_REFRESH_TOKEN_MISSING_OR_TOO_SHORT" 22

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
TMP_DIR="$(mktemp -d "$RUNTIME_DIR/.guardian-master.XXXXXX")"
chmod 700 "$TMP_DIR"

download_and_verify() {
  local label="$1"
  local url="$2"
  local expected_sha="$3"
  local target="$4"

  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 60 \
    -H 'cache-control: no-cache' \
    -H "user-agent: openclaw-guardian-master-installer/1-$label" \
    "$url" > "$target"

  chmod 600 "$target"
  printf '%s  %s\n' "$expected_sha" "$target" | sha256sum --check --status \
    || fail "${label}_INSTALLER_SHA256_MISMATCH" 30

  head -n 1 "$target" | grep -Fqx '#!/usr/bin/env bash' \
    || fail "${label}_INSTALLER_SHEBANG_INVALID" 31

  if grep -Eq '^[[:space:]]*(export[[:space:]]+)?(OPENCODE_API_KEY|TAILSCALE_AUTHKEY)=' "$target"; then
    fail "${label}_INSTALLER_CONTAINS_LEGACY_PROVIDER_SECRET_EXPORT" 32
  fi
}

MODEL_INSTALLER="$TMP_DIR/model-auth-recovery.sh"
WORKER_INSTALLER="$TMP_DIR/recovery-queue-worker.sh"

download_and_verify "MODEL_AUTH" "$MODEL_INSTALLER_URL" "$MODEL_INSTALLER_SHA256" "$MODEL_INSTALLER"
download_and_verify "RECOVERY_WORKER" "$WORKER_INSTALLER_URL" "$WORKER_INSTALLER_SHA256" "$WORKER_INSTALLER"

grep -Fq 'agents.defaults.model' "$MODEL_INSTALLER" \
  || fail "MODEL_INSTALLER_REPAIR_CONTRACT_MISSING" 33
grep -Fq 'provider_secret_returned' "$MODEL_INSTALLER" \
  || fail "MODEL_INSTALLER_SECRET_BOUNDARY_RECEIPT_MISSING" 34
grep -Fq 'openclaw-recovery-queue-worker' "$WORKER_INSTALLER" \
  || fail "WORKER_INSTALLER_SERVICE_CONTRACT_MISSING" 35
grep -Fq 'ProtectSystem=strict' "$WORKER_INSTALLER" \
  || fail "WORKER_INSTALLER_HARDENING_CONTRACT_MISSING" 36

log "PHASE=MODEL_AUTH_RECOVERY"
bash "$MODEL_INSTALLER"

log "PHASE=RECOVERY_QUEUE_WORKER"
bash "$WORKER_INSTALLER"

timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
tmp_receipt="$TMP_DIR/receipt.json"
cat > "$tmp_receipt" <<EOF
{
  "ok": true,
  "installed_at": "$timestamp",
  "model_installer_sha256": "$MODEL_INSTALLER_SHA256",
  "worker_installer_sha256": "$WORKER_INSTALLER_SHA256",
  "provider_secret_exported": false,
  "paid_api_fallback": false,
  "second_telegram_poller": false,
  "tailscale_management_api_enabled": false,
  "physical_validation_pending": true
}
EOF
chmod 600 "$tmp_receipt"
mv -f "$tmp_receipt" "$RECEIPT_FILE"
chmod 600 "$RECEIPT_FILE"

log "RESULT=PASS"
log "RECEIPT=$RECEIPT_FILE"
log "NEXT=VERIFY_OPENCLAW_GATEWAY_TELEGRAM_AND_TAILSCALE_STATUS"
