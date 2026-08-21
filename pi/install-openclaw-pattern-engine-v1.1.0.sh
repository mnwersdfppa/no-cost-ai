#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="1.1.0"
REPOSITORY="mnwersdfppa/no-cost-ai"
SOURCE_REF="${OPENCLAW_PATTERN_ENGINE_REF:-feat/supabase-emergency-bridge-20260819}"
SUPABASE_PROJECT_REF="dpllasnpfskyyyzebyal"
MASTER_RECOVERY_URL="https://${SUPABASE_PROJECT_REF}.supabase.co/functions/v1/pi-openclaw-current-master-recovery-verified"
MASTER_RECOVERY_SHA256="d8e4792e759d898a2a3c7434e973b82fdeddd10e291ac1d4973276ece7216419"
INSTALL_ROOT="${OPENCLAW_PATTERN_ENGINE_ROOT:-${HOME}/.local/share/openclaw-pattern-engine}"
OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-${HOME}/.openclaw/workspace}"
SKILL_DIR="${OPENCLAW_WORKSPACE}/skills/pattern-evolution"
WORKFLOW_DIR="${INSTALL_ROOT}/n8n"
WORKFLOW_FILE="${WORKFLOW_DIR}/pattern-event-ingest.workflow.json"
RECEIPT_DIR="${INSTALL_ROOT}/receipts"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RECEIPT_FILE="${RECEIPT_DIR}/install-${STAMP}.json"
IMPORT_MARKER="${WORKFLOW_DIR}/.pattern-event-ingest-v1.1.imported"
TMP_DIR="$(mktemp -d /tmp/openclaw-pattern-engine.XXXXXX)"

cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 127
  }
}

safe_text() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9._:/@+-' | cut -c1-240
}

fetch_repo_file() {
  local source_path="$1"
  local destination="$2"
  local metadata="${TMP_DIR}/$(basename "${source_path}").json"
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 \
    --get \
    --data-urlencode "ref=${SOURCE_REF}" \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "${metadata}" \
    "https://api.github.com/repos/${REPOSITORY}/contents/${source_path}"
  python3 - "${metadata}" "${destination}" <<'PY'
import base64
import json
import pathlib
import sys
source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
payload = json.loads(source.read_text(encoding="utf-8"))
if payload.get("type") != "file" or payload.get("encoding") != "base64":
    raise SystemExit("unexpected GitHub contents response")
content = base64.b64decode(payload["content"], validate=False)
destination.write_bytes(content)
PY
}

need curl
need sha256sum
need python3
need install

ARCH="$(uname -m)"
case "${ARCH}" in
  aarch64|arm64|x86_64|amd64) ;;
  *) printf 'unsupported architecture: %s\n' "${ARCH}" >&2; exit 2 ;;
esac

mkdir -p "${SKILL_DIR}" "${WORKFLOW_DIR}" "${RECEIPT_DIR}"

SKILL_TMP="${TMP_DIR}/SKILL.md"
WORKFLOW_TMP="${TMP_DIR}/pattern-event-ingest.workflow.json"
fetch_repo_file "skills/pattern-evolution/SKILL.md" "${SKILL_TMP}"
fetch_repo_file "n8n/pattern-event-ingest.workflow.json" "${WORKFLOW_TMP}"

grep -Fq 'name: pattern-evolution' "${SKILL_TMP}"
grep -Fq 'version: "1.1.0"' "${SKILL_TMP}"
python3 - "${WORKFLOW_TMP}" <<'PY'
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload.get("active") is False
assert payload.get("name") == "OpenClaw Pattern Event Ingest v1.1 (inactive)"
rendered = json.dumps(payload, ensure_ascii=False)
assert "CHANGE_ME.invalid" in rendered
assert "automaticActivation\": false" in rendered
PY

if grep -Eqi '(sk-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})' "${SKILL_TMP}" "${WORKFLOW_TMP}"; then
  printf 'secret-like literal detected in prepared artifacts\n' >&2
  exit 3
fi

if [[ "${SKIP_OPENCLAW_RECOVERY:-0}" != "1" ]]; then
  RECOVERY_SCRIPT="${TMP_DIR}/openclaw-current-master-recovery.sh"
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 \
    --output "${RECOVERY_SCRIPT}" \
    "${MASTER_RECOVERY_URL}"
  printf '%s  %s\n' "${MASTER_RECOVERY_SHA256}" "${RECOVERY_SCRIPT}" | sha256sum --check --status
  chmod 0700 "${RECOVERY_SCRIPT}"
  bash "${RECOVERY_SCRIPT}"
  RECOVERY_STATE="executed_verified"
else
  RECOVERY_STATE="skipped_by_explicit_environment_flag"
fi

if [[ -f "${SKILL_DIR}/SKILL.md" ]]; then
  cp -p "${SKILL_DIR}/SKILL.md" "${SKILL_DIR}/SKILL.md.backup-${STAMP}"
fi
install -m 0600 "${SKILL_TMP}" "${SKILL_DIR}/SKILL.md"
install -m 0600 "${WORKFLOW_TMP}" "${WORKFLOW_FILE}"

SKILL_SHA256="$(sha256sum "${SKILL_DIR}/SKILL.md" | awk '{print $1}')"
WORKFLOW_SHA256="$(sha256sum "${WORKFLOW_FILE}" | awk '{print $1}')"
N8N_STATE="not_attempted"
N8N_LOG="${WORKFLOW_DIR}/import-${STAMP}.log"

if [[ "${IMPORT_N8N_WORKFLOW:-1}" == "1" ]]; then
  if [[ -f "${IMPORT_MARKER}" ]]; then
    N8N_STATE="already_imported_inactive"
  elif command -v n8n >/dev/null 2>&1; then
    set +e
    n8n import:workflow --input="${WORKFLOW_FILE}" >"${N8N_LOG}" 2>&1
    RC=$?
    set -e
    if [[ ${RC} -eq 0 ]]; then
      : > "${IMPORT_MARKER}"
      chmod 0600 "${IMPORT_MARKER}"
      N8N_STATE="imported_inactive_host_cli"
    else
      N8N_STATE="host_cli_import_failed_rc_${RC}"
    fi
  elif command -v docker >/dev/null 2>&1; then
    mapfile -t N8N_CONTAINERS < <(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null | awk 'tolower($0) ~ /n8n/ {print $1}')
    if [[ ${#N8N_CONTAINERS[@]} -eq 1 ]]; then
      CID="${N8N_CONTAINERS[0]}"
      set +e
      docker cp "${WORKFLOW_FILE}" "${CID}:/tmp/openclaw-pattern-event-ingest.workflow.json" >"${N8N_LOG}" 2>&1 \
        && docker exec "${CID}" n8n import:workflow --input=/tmp/openclaw-pattern-event-ingest.workflow.json >>"${N8N_LOG}" 2>&1
      RC=$?
      set -e
      if [[ ${RC} -eq 0 ]]; then
        : > "${IMPORT_MARKER}"
        chmod 0600 "${IMPORT_MARKER}"
        N8N_STATE="imported_inactive_docker_cli"
      else
        N8N_STATE="docker_cli_import_failed_rc_${RC}"
      fi
    elif [[ ${#N8N_CONTAINERS[@]} -gt 1 ]]; then
      N8N_STATE="blocked_multiple_n8n_containers"
    else
      N8N_STATE="n8n_cli_or_running_container_not_found"
    fi
  else
    N8N_STATE="n8n_cli_not_found"
  fi
else
  N8N_STATE="skipped_by_explicit_environment_flag"
fi

MODEL="unknown"
if command -v openclaw >/dev/null 2>&1; then
  MODEL_RAW="$(openclaw config get agents.defaults.model 2>/dev/null | tail -n 1 || true)"
  [[ -n "${MODEL_RAW}" ]] && MODEL="$(safe_text "${MODEL_RAW}")"
fi

HOST_SAFE="$(safe_text "$(hostname 2>/dev/null || printf unknown)")"
COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "${RECEIPT_FILE}" <<EOF
{
  "receipt_type": "openclaw_pattern_engine_physical_install",
  "bundle_version": "${VERSION}",
  "completed_at": "${COMPLETED_AT}",
  "host": "${HOST_SAFE}",
  "architecture": "${ARCH}",
  "source_repository": "${REPOSITORY}",
  "source_ref": "${SOURCE_REF}",
  "recovery_state": "${RECOVERY_STATE}",
  "skill_path": "${SKILL_DIR}/SKILL.md",
  "skill_sha256": "${SKILL_SHA256}",
  "n8n_workflow_path": "${WORKFLOW_FILE}",
  "n8n_workflow_sha256": "${WORKFLOW_SHA256}",
  "n8n_state": "${N8N_STATE}",
  "n8n_workflow_active": false,
  "configured_model": "${MODEL}",
  "paid_fallback_enabled": false,
  "second_telegram_poller_created": false,
  "provider_secret_exported": false,
  "secret_values_included": false
}
EOF
chmod 0600 "${RECEIPT_FILE}"

printf 'OpenClaw Pattern Evolution Engine %s prepared on this host.\n' "${VERSION}"
printf 'Recovery: %s\n' "${RECOVERY_STATE}"
printf 'Skill: %s\n' "${SKILL_DIR}/SKILL.md"
printf 'n8n: %s; imported workflow remains inactive.\n' "${N8N_STATE}"
printf 'Receipt: %s\n' "${RECEIPT_FILE}"
printf 'Remaining physical gates: Telegram /model default -s -> /new -> /status, real message receipt, T4 correlation round-trip, and rollback receipt.\n'
