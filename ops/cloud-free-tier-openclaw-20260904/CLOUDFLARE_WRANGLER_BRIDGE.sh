#!/usr/bin/env bash
set -euo pipefail

BASE="ops/cloud-free-tier-openclaw-20260904"
BUCKET="openclaw-brain-backup"
WORKER="openclaw-telegram-edge"

command -v node >/dev/null || { echo 'NODE_MISSING'; exit 20; }
command -v npm >/dev/null || { echo 'NPM_MISSING'; exit 21; }

if ! npx --yes wrangler@latest whoami >/tmp/wrangler-whoami.txt 2>&1; then
  echo 'CLOUDFLARE_OAUTH_REQUIRED'
  npx --yes wrangler@latest login
fi
npx --yes wrangler@latest whoami

if ! npx --yes wrangler@latest r2 bucket list 2>/dev/null | grep -q "$BUCKET"; then
  npx --yes wrangler@latest r2 bucket create "$BUCKET"
fi

cat > /tmp/openclaw-wrangler.toml <<EOF
name = "$WORKER"
main = "$BASE/cloudflare-worker.js"
compatibility_date = "2026-09-04"

[[r2_buckets]]
binding = "OPENCLAW_BACKUP"
bucket_name = "$BUCKET"
EOF

npx --yes wrangler@latest deploy --config /tmp/openclaw-wrangler.toml
printf 'CLOUDFLARE_EDGE_BRIDGE_OK worker=%s r2=%s\n' "$WORKER" "$BUCKET"
