#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/mnwersdfppa/no-cost-ai.git"
BRANCH="ops/cloud-free-tier-openclaw-20260904"
REMOTE_DIR="/opt/openclaw-cloud"

command -v oci >/dev/null || { echo 'OCI_CLI_MISSING'; exit 20; }
command -v jq >/dev/null || { echo 'JQ_MISSING'; exit 21; }

# Discover running Oracle instances without requiring the user to paste OCIDs.
RAW="$(oci search resource structured-search --query-text "query instance resources where lifecycleState = 'RUNNING'" --all 2>/dev/null || true)"
COUNT="$(printf '%s' "$RAW" | jq '.data.items | length' 2>/dev/null || echo 0)"
[ "$COUNT" -gt 0 ] || { echo 'NO_RUNNING_ORACLE_INSTANCE_FOUND'; exit 30; }

# Prefer Ampere A1; otherwise take the first running VM.
INSTANCE_ID="$(printf '%s' "$RAW" | jq -r '[.data.items[] | select((."resource-type" // "") == "Instance") | select((.shape // ."additional-details".shape // "") | contains("A1"))][0].identifier // empty')"
if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID="$(printf '%s' "$RAW" | jq -r '[.data.items[] | select((."resource-type" // "") == "Instance")][0].identifier // empty')"
fi
[ -n "$INSTANCE_ID" ] || { echo 'ORACLE_INSTANCE_ID_NOT_RESOLVED'; exit 31; }

COMPARTMENT_ID="$(printf '%s' "$RAW" | jq -r --arg id "$INSTANCE_ID" '.data.items[] | select(.identifier==$id) | ."compartment-id" // empty')"
DETAIL="$(oci compute instance get --instance-id "$INSTANCE_ID")"
SHAPE="$(printf '%s' "$DETAIL" | jq -r '.data.shape // "unknown"')"
NAME="$(printf '%s' "$DETAIL" | jq -r '.data."display-name" // "oracle-openclaw"')"

VNIC_ID="$(oci compute vnic-attachment list --compartment-id "$COMPARTMENT_ID" --instance-id "$INSTANCE_ID" --all | jq -r '.data[0]."vnic-id" // empty')"
[ -n "$VNIC_ID" ] || { echo 'ORACLE_VNIC_NOT_FOUND'; exit 32; }
VNIC="$(oci network vnic get --vnic-id "$VNIC_ID")"
PUBLIC_IP="$(printf '%s' "$VNIC" | jq -r '.data."public-ip" // empty')"
PRIVATE_IP="$(printf '%s' "$VNIC" | jq -r '.data."private-ip" // empty')"
[ -n "$PUBLIC_IP" ] || { echo "ORACLE_PUBLIC_IP_MISSING private=$PRIVATE_IP"; exit 33; }

echo "ORACLE_TARGET name=$NAME shape=$SHAPE ip=$PUBLIC_IP"

KEYS=()
for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/oci" "$HOME/.ssh/oci_api_key"; do
  [ -f "$k" ] && KEYS+=("$k")
done
[ ${#KEYS[@]} -gt 0 ] || { echo 'NO_CLOUD_SHELL_SSH_PRIVATE_KEY_FOUND'; exit 34; }

REMOTE_USER=""
REMOTE_KEY=""
for key in "${KEYS[@]}"; do
  for user in ubuntu opc; do
    if ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$user@$PUBLIC_IP" 'printf ORACLE_SSH_OK' 2>/dev/null | grep -q ORACLE_SSH_OK; then
      REMOTE_USER="$user"; REMOTE_KEY="$key"; break 2
    fi
  done
done
[ -n "$REMOTE_USER" ] || { echo 'ORACLE_SSH_AUTH_NOT_MATCHED'; exit 35; }

echo "ORACLE_SSH_OK user=$REMOTE_USER"

ssh -i "$REMOTE_KEY" -o StrictHostKeyChecking=accept-new "$REMOTE_USER@$PUBLIC_IP" "bash -s" <<'REMOTE'
set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl git docker.io docker-compose-v2 || sudo apt-get install -y ca-certificates curl git docker.io docker-compose-plugin
  sudo systemctl enable --now docker
fi
sudo mkdir -p /opt/openclaw-cloud
sudo chown "$USER":"$USER" /opt/openclaw-cloud
if [ ! -d /opt/openclaw-cloud/.git ]; then
  git clone --depth 1 --branch ops/cloud-free-tier-openclaw-20260904 https://github.com/mnwersdfppa/no-cost-ai.git /opt/openclaw-cloud
else
  cd /opt/openclaw-cloud
  git fetch origin ops/cloud-free-tier-openclaw-20260904
  git checkout ops/cloud-free-tier-openclaw-20260904
  git reset --hard origin/ops/cloud-free-tier-openclaw-20260904
fi
mkdir -p "$HOME/.openclaw" "$HOME/.openclaw/workspace"
cd /opt/openclaw-cloud
if [ -f ops/cloud-free-tier-openclaw-20260904/docker-compose.oracle.yml ]; then
  docker compose -f ops/cloud-free-tier-openclaw-20260904/docker-compose.oracle.yml config >/tmp/openclaw-compose-check.txt 2>&1 || true
fi
printf 'ORACLE_DOCKER_BRIDGE_READY\n'
REMOTE

printf 'ORACLE_CLOUD_SHELL_BRIDGE_OK ip=%s user=%s shape=%s\n' "$PUBLIC_IP" "$REMOTE_USER" "$SHAPE"
