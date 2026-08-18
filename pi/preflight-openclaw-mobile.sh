#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$ROOT/secrets}"
RECEIPTS="$ROOT/receipts"
mkdir -p "$RECEIPTS"
chmod 700 "$ROOT" "$RECEIPTS" 2>/dev/null || true
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$RECEIPTS/mobile-preflight-$STAMP.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

safe_run() {
  local name="$1"; shift
  set +e
  timeout 30 "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"
  local rc=$?
  set -e
  python3 - "$name" "$rc" "$TMP/$name.out" "$TMP/$name.err" <<'PY'
import json,re,sys
name,rc,out_path,err_path=sys.argv[1:]
def clean(s):
    patterns=[
      r'sk-proj-[A-Za-z0-9_-]+',r'sk-[A-Za-z0-9_-]{20,}',r'ghp_[A-Za-z0-9]{20,}',
      r'Bearer\s+[A-Za-z0-9._-]+',r'(?i)(token|password|secret|api[_-]?key)\s*[:=]\s*\S+'
    ]
    for p in patterns: s=re.sub(p,'[REDACTED]',s)
    return s[:8000]
print(json.dumps({"name":name,"returncode":int(rc),"stdout":clean(open(out_path,errors='replace').read()),"stderr":clean(open(err_path,errors='replace').read())},ensure_ascii=False))
PY
}

checks=()
for cmd in openclaw adb node npm python3 curl git systemctl ollama tailscale; do
  if command -v "$cmd" >/dev/null 2>&1; then
    checks+=("$cmd=present")
  else
    checks+=("$cmd=missing")
  fi
done

records="$TMP/records.jsonl"
: > "$records"
command -v openclaw >/dev/null 2>&1 && {
  safe_run openclaw_version openclaw --version >> "$records"
  safe_run gateway_status openclaw gateway status >> "$records"
  safe_run openclaw_status openclaw status >> "$records"
  safe_run mcp_status openclaw mcp status --verbose >> "$records"
  safe_run model_auth openclaw models auth status >> "$records"
  safe_run model_list openclaw models list >> "$records"
  safe_run node_status openclaw nodes status >> "$records"
  safe_run device_list openclaw devices list --json >> "$records"
}
command -v adb >/dev/null 2>&1 && safe_run adb_devices adb devices -l >> "$records"
command -v ollama >/dev/null 2>&1 && safe_run ollama_list ollama list >> "$records"
command -v tailscale >/dev/null 2>&1 && safe_run tailscale_status tailscale status --json >> "$records"

python3 - "$OUT" "$SECRETS" "$records" "${checks[*]}" <<'PY'
import json,os,re,stat,sys
out,secrets,records,checks=sys.argv[1:]
secret_files=[]
if os.path.isdir(secrets):
    for name in sorted(os.listdir(secrets)):
        path=os.path.join(secrets,name)
        if not os.path.isfile(path): continue
        mode=oct(stat.S_IMODE(os.stat(path).st_mode))
        keys=[]
        try:
            for line in open(path,encoding='utf-8',errors='replace'):
                m=re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=',line.strip())
                if m: keys.append(m.group(1))
        except Exception: pass
        secret_files.append({"name":name,"mode":mode,"variable_names":keys})
items=[]
for line in open(records,encoding='utf-8'):
    line=line.strip()
    if line: items.append(json.loads(line))
payload={
  "result":"preflight_only",
  "created_at":__import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat(),
  "commands":dict(item.split('=',1) for item in checks.split()),
  "secret_files":secret_files,
  "checks":items,
  "secret_values_exposed":False,
  "mutations_performed":False
}
with open(out,'w',encoding='utf-8') as f: json.dump(payload,f,ensure_ascii=False,indent=2)
os.chmod(out,0o600)
PY

echo "RESULT=PREFLIGHT_COMPLETE"
echo "RECEIPT=$OUT"
echo "MUTATIONS=NONE"
