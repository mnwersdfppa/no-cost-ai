#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DST="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}/skills/fastpath"
BACKUP="${DST}.backup.$(date -u +%Y%m%dT%H%M%SZ)"

command -v openclaw >/dev/null 2>&1 || { echo 'BLOCKED=OPENCLAW_NOT_FOUND' >&2; exit 20; }
command -v python3 >/dev/null 2>&1 || { echo 'BLOCKED=PYTHON3_NOT_FOUND' >&2; exit 21; }

mkdir -p "$(dirname "$DST")"
if [[ -d "$DST" ]]; then
  cp -a "$DST" "$BACKUP"
fi
rm -rf "$DST"
mkdir -p "$DST"
cp "$SRC/SKILL.md" "$SRC/policy.json" "$SRC/router.py" "$DST/"
chmod 755 "$DST/router.py"
chmod 644 "$DST/SKILL.md" "$DST/policy.json"

python3 -m json.tool "$DST/policy.json" >/dev/null
python3 -m py_compile "$DST/router.py"
openclaw skills list | grep -i fastpath >/dev/null || true

if openclaw gateway restart --help 2>&1 | grep -q -- '--safe'; then
  openclaw gateway restart --safe || true
else
  openclaw gateway restart || true
fi

openclaw skills list | grep -i fastpath >/dev/null || {
  echo 'BLOCKED=FASTPATH_NOT_DISCOVERED'
  echo "SKILL_PATH=$DST"
  echo 'NEXT=start a new OpenClaw session or inspect skill loading order'
  exit 22
}

echo 'RESULT=FASTPATH_SKILL_INSTALLED'
echo "SKILL_PATH=$DST"
echo 'MODEL_INVOCATION=AUTO'
echo 'PAID_API_AUTOMATIC_FALLBACK=OFF'
echo 'CHAIN_OF_THOUGHT_STORAGE=OFF'
