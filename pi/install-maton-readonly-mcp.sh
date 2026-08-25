#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$ROOT/secrets}"
SOURCE_ENV="${MATON_ENV_FILE:-$SECRETS/maton.env}"
NORMALIZED_ENV="$SECRETS/maton-openclaw.env"
DROPIN="$HOME/.config/systemd/user/openclaw-gateway.service.d/30-maton-env.conf"
NAME="maton-readonly"

command -v openclaw >/dev/null 2>&1 || { echo 'BLOCKED=OPENCLAW_NOT_FOUND' >&2; exit 20; }
[[ -r "$SOURCE_ENV" ]] || { echo "BLOCKED=MATON_ENV_MISSING:$SOURCE_ENV" >&2; exit 21; }

set -a
# shellcheck disable=SC1090
source "$SOURCE_ENV"
set +a

MATON_MCP_URL="${MATON_MCP_URL:-${MATON_BASE_URL:-}}"
MATON_NORMALIZED_KEY="${MATON_API_KEY:-${MATON_API_TOKEN:-${MATON_KEY:-}}}"
[[ "$MATON_MCP_URL" == https://* ]] || { echo 'BLOCKED=MATON_HTTPS_MCP_URL_REQUIRED' >&2; exit 22; }
[[ -n "$MATON_NORMALIZED_KEY" ]] || { echo 'BLOCKED=MATON_API_KEY_NOT_FOUND' >&2; exit 23; }

mkdir -p "$SECRETS" "$(dirname "$DROPIN")"
chmod 700 "$ROOT" "$SECRETS" "$(dirname "$DROPIN")" 2>/dev/null || true
{
  printf 'MATON_API_KEY=%q\n' "$MATON_NORMALIZED_KEY"
  printf 'MATON_MCP_URL=%q\n' "$MATON_MCP_URL"
} > "$NORMALIZED_ENV"
chmod 600 "$NORMALIZED_ENV"

cat > "$DROPIN" <<EOF
[Service]
EnvironmentFile=$NORMALIZED_ENV
EOF
chmod 600 "$DROPIN"
systemctl --user daemon-reload

CONFIG="$(python3 - "$MATON_MCP_URL" <<'PY'
import json,sys
url=sys.argv[1]
print(json.dumps({
  "url":url,
  "transport":"streamable-http",
  "headers":{"Authorization":"Bearer $MATON_API_KEY"},
  "enabled":True,
  "connectionTimeoutMs":10000,
  "requestTimeoutMs":30000,
  "toolFilter":{"include":["whoami","search_apps","search_actions","get_action","get_connection","list_connections"]},
  "codex":{"defaultToolsApprovalMode":"prompt"}
},separators=(',',':')))
PY
)"

openclaw mcp set "$NAME" "$CONFIG"
if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
  openclaw gateway restart --safe
else
  openclaw gateway restart
fi

if openclaw mcp doctor "$NAME" --probe; then
  echo 'RESULT=MATON_READONLY_READY'
  echo 'WRITE_TOOLS=EXCLUDED'
  echo 'SECRET_VALUES_EXPOSED=NO'
else
  openclaw mcp configure "$NAME" --disable || true
  echo 'RESULT=MATON_READONLY_DISABLED_AFTER_FAILED_PROBE'
  echo 'NEXT=verify MATON_MCP_URL, authentication scope, and official Maton tool names'
  exit 24
fi
