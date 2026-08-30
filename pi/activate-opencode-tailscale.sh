#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Backward-compatible command name. All recovery logic is centralized in the
# SHA-verified Supabase-first installer wrapper; no provider key is stored here.
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CANONICAL="$SCRIPT_DIR/recover-opencode-first-tailscale-second.sh"

if [[ ! -f "$CANONICAL" ]]; then
  printf 'RESULT=BLOCKED\nBLOCKER=CANONICAL_RECOVERY_SCRIPT_MISSING:%s\n' "$CANONICAL" >&2
  exit 20
fi
if [[ ! -x "$CANONICAL" ]]; then
  chmod 700 "$CANONICAL" 2>/dev/null || true
fi

exec "$CANONICAL" "$@"
