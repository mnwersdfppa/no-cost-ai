#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

STATE="${OPENCLAW_PHONE_STATE:-$HOME/.openclaw-phone}"
CODEX_VERSION="${PHONE_CODEX_VERSION:-0.146.0}"
EXPECTED_VERSION="0.146.0"
EXPECTED_INTEGRITY="sha512-yG3sPWNda/2YAIQIDq9MrrjoCTIQ7rxYM5IasrG3VBcuhCLTkgeg/JzqmJq1V98RE4MJ5jCxDXXQlOjrditFRw=="
EXPECTED_SHASUM="082252be01f29dff4b7b7b14ceb6e103a7df7777"
EXPECTED_TARBALL="https://registry.npmjs.org/@openai/codex/-/codex-0.146.0.tgz"
RECEIPT="$STATE/codex-package-receipt.json"
INSTALL_CODEX="${INSTALL_CODEX:-1}"

if [[ "$CODEX_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "BLOCKED=CODEX_VERSION_NOT_REVIEWED"
  echo "REQUIRED=$EXPECTED_VERSION"
  echo "REQUESTED=$CODEX_VERSION"
  exit 71
fi

if command -v pkg >/dev/null 2>&1; then
  pkg install -y nodejs-lts python coreutils >/dev/null 2>&1 \
    || pkg install -y nodejs python coreutils >/dev/null 2>&1
fi
for command_name in npm python sha1sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "BLOCKED=MISSING_COMMAND:$command_name"
    exit 72
  }
done

mkdir -p "$STATE"
chmod 700 "$STATE"

installed_version() {
  codex --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

receipt_ok=0
if [[ -s "$RECEIPT" ]]; then
  receipt_ok="$(python - "$RECEIPT" "$EXPECTED_VERSION" "$EXPECTED_INTEGRITY" "$EXPECTED_SHASUM" <<'PY'
import json,sys
path,version,integrity,shasum=sys.argv[1:]
try:
    data=json.load(open(path,encoding='utf-8'))
except Exception:
    print(0)
    raise SystemExit
ok=(data.get('version')==version and data.get('integrity')==integrity and data.get('shasum')==shasum and data.get('verified') is True)
print(1 if ok else 0)
PY
)"
fi

CURRENT="$(installed_version)"
if [[ "$CURRENT" == "$EXPECTED_VERSION" && "$receipt_ok" == "1" ]]; then
  echo "CODEX_PACKAGE=VERIFIED_CACHED"
  echo "CODEX_VERSION=$CURRENT"
  exit 0
fi

if [[ "$INSTALL_CODEX" != "1" ]]; then
  echo "BLOCKED=VERIFIED_CODEX_INSTALL_REQUIRED"
  echo "FOUND=${CURRENT:-missing}"
  exit 73
fi

actual_integrity="$(npm view "@openai/codex@$EXPECTED_VERSION" dist.integrity)"
actual_shasum="$(npm view "@openai/codex@$EXPECTED_VERSION" dist.shasum)"
actual_tarball="$(npm view "@openai/codex@$EXPECTED_VERSION" dist.tarball)"
if [[ "$actual_integrity" != "$EXPECTED_INTEGRITY" || "$actual_shasum" != "$EXPECTED_SHASUM" || "$actual_tarball" != "$EXPECTED_TARBALL" ]]; then
  echo "BLOCKED=CODEX_REGISTRY_METADATA_CHANGED"
  exit 74
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
npm pack "@openai/codex@$EXPECTED_VERSION" --pack-destination "$TMP" >/dev/null
mapfile -t archives < <(find "$TMP" -maxdepth 1 -type f -name '*.tgz' -print)
if [[ ${#archives[@]} -ne 1 ]]; then
  echo "BLOCKED=CODEX_ARCHIVE_COUNT_INVALID"
  exit 75
fi
ARCHIVE="${archives[0]}"
computed_shasum="$(sha1sum "$ARCHIVE" | awk '{print $1}')"
computed_integrity="$(python - "$ARCHIVE" <<'PY'
import base64,hashlib,sys
payload=open(sys.argv[1],'rb').read()
print('sha512-'+base64.b64encode(hashlib.sha512(payload).digest()).decode('ascii'))
PY
)"
if [[ "$computed_shasum" != "$EXPECTED_SHASUM" || "$computed_integrity" != "$EXPECTED_INTEGRITY" ]]; then
  echo "BLOCKED=CODEX_ARCHIVE_INTEGRITY_MISMATCH"
  exit 76
fi

npm install -g "$ARCHIVE" --no-audit --no-fund
CURRENT="$(installed_version)"
if [[ "$CURRENT" != "$EXPECTED_VERSION" ]]; then
  echo "BLOCKED=CODEX_VERSION_NOT_VERIFIED_AFTER_INSTALL"
  echo "FOUND=${CURRENT:-missing}"
  exit 77
fi

python - "$RECEIPT" "$EXPECTED_VERSION" "$EXPECTED_INTEGRITY" "$EXPECTED_SHASUM" "$EXPECTED_TARBALL" <<'PY'
import json,os,sys
path,version,integrity,shasum,tarball=sys.argv[1:]
with open(path,'w',encoding='utf-8') as handle:
    json.dump({
        'package':'@openai/codex',
        'version':version,
        'integrity':integrity,
        'shasum':shasum,
        'tarball':tarball,
        'verified':True,
    },handle,ensure_ascii=False,indent=2)
os.chmod(path,0o600)
PY

echo "CODEX_PACKAGE=VERIFIED_INSTALLED"
echo "CODEX_VERSION=$CURRENT"
