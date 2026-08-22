#!/usr/bin/env bash
set -euo pipefail

SRC="${ULTRA_COMPRESS_SKILL_SRC:-$HOME/no-cost-ai/skills/ultra-compress-priority}"
DST="${OPENCLAW_SKILLS_DIR:-$HOME/.openclaw/workspace/skills}/ultra-compress-priority"

[[ -d "$SRC" ]] || { echo "BLOCKED=SKILL_SOURCE_MISSING:$SRC" >&2; exit 20; }
command -v python3 >/dev/null 2>&1 || { echo 'BLOCKED=PYTHON3_REQUIRED' >&2; exit 21; }

python3 "$SRC/scripts/quick_validate.py" "$SRC"
mkdir -p "$(dirname "$DST")"
rm -rf "$DST.tmp"
mkdir -p "$DST.tmp"
cp -R "$SRC"/. "$DST.tmp"/
python3 "$DST.tmp/scripts/quick_validate.py" "$DST.tmp"
rm -rf "$DST"
mv "$DST.tmp" "$DST"

if command -v openclaw >/dev/null 2>&1; then
  openclaw skills list || true
  openclaw gateway restart --safe 2>/dev/null || openclaw gateway restart 2>/dev/null || true
fi

echo 'RESULT=ULTRA_COMPRESS_PRIORITY_SKILL_INSTALLED'
echo "SKILL_DIR=$DST"
echo 'AUTO_USE=via_model_discovery_description'
echo 'PAID_OPENAI_AUTO_FALLBACK=OFF'
