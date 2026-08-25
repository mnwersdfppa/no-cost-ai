#!/usr/bin/env bash
set -euo pipefail

VALUE="${1:-}"
ENV_FILE="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}/phone-bridge.env"
[[ "$VALUE" =~ ^SHA256:[A-Za-z0-9+/=]+$ ]] || { echo 'USAGE: set-phone-ssh-fingerprint.sh SHA256:...' >&2; exit 20; }
[[ -f "$ENV_FILE" ]] || { echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING:$ENV_FILE" >&2; exit 21; }

python3 - "$ENV_FILE" "$VALUE" <<'PY'
import os,re,sys
path,value=sys.argv[1:]
lines=open(path,encoding='utf-8').read().splitlines()
out=[]
replaced=False
for line in lines:
    if line.startswith('PHONE_SSH_HOST_KEY_SHA256='):
        out.append('PHONE_SSH_HOST_KEY_SHA256='+value)
        replaced=True
    else:
        out.append(line)
if not replaced: out.append('PHONE_SSH_HOST_KEY_SHA256='+value)
with open(path,'w',encoding='utf-8') as f: f.write('\n'.join(out)+'\n')
os.chmod(path,0o600)
PY

echo 'RESULT=PHONE_SSH_FINGERPRINT_RECORDED'
echo 'VALUE_NOT_REPRINTED=YES'
