bash <<'OPENCLAW_PI_AUTH_REPAIR'
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
SECRETS_DIR="$ROOT/secrets"
RUNTIME_DIR="$ROOT/runtime"
RECEIPT_DIR="$ROOT/receipts"
LOCK_DIR="$ROOT/locks"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$SECRETS_DIR/pi-work-queue.env}"
AUTH_RECEIPT="$RECEIPT_DIR/pi-auth-repair-20260821.json"
FULL_RECEIPT="$RECEIPT_DIR/full-recovery-dispatcher-20260821.json"
RESUME_RECEIPT="$RECEIPT_DIR/resume-recovery-20260821.json"
FINALIZER_RECEIPT="$RUNTIME_DIR/pi-model-route-finalizer-receipt.json"
LOCK_FILE="$LOCK_DIR/pi-auth-repair-20260821.lock"

DISPATCHER="/tmp/pi-full-recovery-dispatcher-verified-20260821.sh"
DISPATCHER_URL="https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-full-recovery-dispatcher-verified-20260821"
DISPATCHER_SHA256="fc248236b9737cd816ba95349e87f3210b3680159ba2e293e88c544715685227"
DISPATCHER_BYTES="4557"
CORRELATION_ID="T4-FULL-RECOVERY-20260821"
UNIT="openclaw-full-recovery-auth-repaired-$(date +%s)"
SERVICE="${UNIT}.service"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$SECRETS_DIR" "$RUNTIME_DIR" "$RECEIPT_DIR" "$LOCK_DIR"
chmod 700 "$ROOT" "$SECRETS_DIR" "$RUNTIME_DIR" "$RECEIPT_DIR" "$LOCK_DIR" 2>/dev/null || true

for command in bash curl python3 sha256sum systemctl systemd-run flock wc tr; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'AUTH_REPAIR_BLOCKED reason=missing_command command=%s\n' "$command"
    exit 40
  }
done

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  printf 'AUTH_REPAIR_SKIPPED reason=already_running\n'
  exit 0
fi
chmod 600 "$LOCK_FILE"

printf '\n[1/6] 이전 복구 작업 종료 여부 확인\n'

for ((i=1; i<=60; i++)); do
  ACTIVE_UNITS="$(
    systemctl --user list-units \
      --type=service \
      --state=activating,running \
      --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^openclaw-full-recovery-.*\.service$' \
    || true
  )"

  if [[ -z "$ACTIVE_UNITS" ]]; then
    break
  fi

  if (( i == 60 )); then
    printf 'AUTH_REPAIR_BLOCKED reason=previous_recovery_still_running units=%s\n' \
      "$(printf '%s' "$ACTIVE_UNITS" | tr '\n' ',')"
    exit 41
  fi

  sleep 5
done

printf '\n[2/6] 로컬 백업에서 Supabase Pi 세션 복구\n'

if python3 - "$ROOT" "$ENV_FILE" "$AUTH_RECEIPT" <<'PY'
from __future__ import annotations

import datetime
import hashlib
import json
import os
import pathlib
import re
import shlex
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid

root = pathlib.Path(sys.argv[1]).expanduser().resolve()
env_file = pathlib.Path(sys.argv[2]).expanduser()
receipt = pathlib.Path(sys.argv[3]).expanduser()

supabase_url = "https://dpllasnpfskyyyzebyal.supabase.co"
refresh_url = f"{supabase_url}/functions/v1/pi-auth-refresh"
bootstrap_url = f"{supabase_url}/functions/v1/pi-infra-bootstrap"

env_pattern = re.compile(
    r"(?m)^\s*(?:export\s+)?PI_REFRESH_TOKEN\s*=\s*(.*?)\s*$"
)
allowed_key = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

def safe_text(path: pathlib.Path) -> str | None:
    try:
        if not path.is_file() or path.stat().st_size > 524_288:
            return None
        if path.suffix.lower() in {".log", ".sqlite", ".db"}:
            return None
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None

def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    try:
        parsed = shlex.split(value)
        if len(parsed) == 1:
            return parsed[0]
    except ValueError:
        pass
    return value

def variants(raw: str):
    queue = [raw]
    seen: set[str] = set()
    while queue:
        value = queue.pop(0)
        value = value.strip().replace("\x00", "")
        if not value or value in seen:
            continue
        seen.add(value)
        yield value

        stripped = unquote(value)
        if stripped not in seen:
            queue.append(stripped)

        compact = value.replace("\r", "").replace("\n", "").strip()
        if compact not in seen:
            queue.append(compact)

        decoded = urllib.parse.unquote(value)
        if decoded not in seen:
            queue.append(decoded)

        try:
            parsed = json.loads(value)
            if isinstance(parsed, str) and parsed not in seen:
                queue.append(parsed)
            elif isinstance(parsed, dict):
                candidate = parsed.get("refresh_token") or parsed.get("PI_REFRESH_TOKEN")
                if isinstance(candidate, str) and candidate not in seen:
                    queue.append(candidate)
        except Exception:
            pass

def collect_json(value, source: pathlib.Path, out):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in {"refresh_token", "PI_REFRESH_TOKEN"} and isinstance(item, str):
                out.append((item, source))
            collect_json(item, source, out)
    elif isinstance(value, list):
        for item in value[:200]:
            collect_json(item, source, out)

def parse_env(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, value = line.split("=", 1)
        key = key.strip()
        if allowed_key.fullmatch(key):
            values[key] = unquote(value)
    return values

files: list[pathlib.Path] = []
if env_file.exists():
    files.append(env_file)

for base in (root / "secrets", root / "runtime", root / "receipts"):
    if not base.exists():
        continue
    for path in base.rglob("*"):
        if len(files) >= 250:
            break
        if not path.is_file():
            continue
        lower = path.name.lower()
        if any(word in lower for word in (
            "pi-work-queue", "session", "bootstrap", "recovery", "auth"
        )):
            files.append(path)

unique_files = []
seen_paths = set()
for path in files:
    try:
        resolved = path.resolve()
    except OSError:
        continue
    if resolved not in seen_paths:
        unique_files.append(resolved)
        seen_paths.add(resolved)

candidates: list[tuple[str, pathlib.Path]] = []
env_maps: list[tuple[dict[str, str], pathlib.Path]] = []

for path in unique_files:
    text = safe_text(path)
    if text is None:
        continue

    values = parse_env(text)
    if values:
        env_maps.append((values, path))
        token = values.get("PI_REFRESH_TOKEN")
        if token:
            candidates.append((token, path))

    for match in env_pattern.finditer(text):
        candidates.append((match.group(1), path))

    try:
        parsed = json.loads(text)
    except Exception:
        parsed = None
    if parsed is not None:
        collect_json(parsed, path, candidates)

deduped: list[tuple[str, pathlib.Path]] = []
seen_candidates: set[str] = set()

for raw, source in candidates:
    for candidate in variants(raw):
        if not (8 <= len(candidate) <= 4096):
            continue
        digest = hashlib.sha256(candidate.encode()).hexdigest()
        if digest in seen_candidates:
            continue
        seen_candidates.add(digest)
        deduped.append((candidate, source))

def post_json(url: str, body: dict, headers: dict[str, str] | None = None):
    request = urllib.request.Request(
        url,
        data=json.dumps(body, separators=(",", ":")).encode(),
        method="POST",
        headers={
            "content-type": "application/json",
            "user-agent": "openclaw-pi-local-auth-repair/1",
            **(headers or {}),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read(131_072)
            return response.status, json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as error:
        error.read(8192)
        return error.code, {}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None, {}

valid = None
source_path = None
method = None

for candidate, source in deduped:
    status, data = post_json(refresh_url, {"refresh_token": candidate})
    if (
        status == 200
        and data.get("ok") is True
        and data.get("role") == "pi-gateway-client"
        and isinstance(data.get("access_token"), str)
        and len(data["access_token"]) >= 20
        and isinstance(data.get("refresh_token"), str)
        and len(data["refresh_token"]) >= 8
    ):
        valid = data
        source_path = source
        method = "local_refresh_candidate"
        break

# Optional fallback: use locally stored Pi email/password only when already present.
if valid is None:
    merged: dict[str, str] = {}
    credential_source = None
    for values, source in env_maps:
        for key, value in values.items():
            if key not in merged and value:
                merged[key] = value
                credential_source = credential_source or source

    email = (
        merged.get("PI_AUTH_EMAIL")
        or merged.get("SUPABASE_AUTH_EMAIL")
        or merged.get("PI_EMAIL")
    )
    password = (
        merged.get("PI_AUTH_PASSWORD")
        or merged.get("SUPABASE_AUTH_PASSWORD")
        or merged.get("PI_PASSWORD")
    )
    publishable = (
        merged.get("SUPABASE_PUBLISHABLE_KEY")
        or merged.get("SUPABASE_ANON_KEY")
    )

    if email and password and publishable:
        login_url = f"{supabase_url}/auth/v1/token?grant_type=password"
        status, data = post_json(
            login_url,
            {"email": email, "password": password},
            {"apikey": publishable},
        )
        if (
            status == 200
            and isinstance(data.get("access_token"), str)
            and isinstance(data.get("refresh_token"), str)
        ):
            check_status, check = post_json(
                bootstrap_url,
                {
                    "action": "status",
                    "execution_key": f"pi-local-auth-repair-{uuid.uuid4()}",
                    "correlation_id": "T4-FULL-RECOVERY-20260821",
                },
                {"authorization": f"Bearer {data['access_token']}"},
            )
            if check_status == 200 and check.get("ok") is True:
                valid = {
                    "access_token": data["access_token"],
                    "refresh_token": data["refresh_token"],
                }
                source_path = credential_source
                method = "local_password_grant"

if valid is None:
    receipt.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "receipt_type": "pi_auth_repair_20260821",
        "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "result": "blocked",
        "blocker": "no_valid_local_refresh_candidate",
        "candidate_count": len(deduped),
        "files_examined": len(unique_files),
        "tokens_printed": False,
        "secret_values_included": False,
    }
    receipt.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    receipt.chmod(0o600)
    print(
        "AUTH_REPAIR_BLOCKED "
        "reason=no_valid_local_refresh_candidate "
        f"candidates={len(deduped)} receipt={receipt}"
    )
    raise SystemExit(42)

existing = {}
if env_file.exists():
    text = safe_text(env_file)
    if text:
        existing = parse_env(text)

existing["SUPABASE_URL"] = supabase_url
existing["PI_ACCESS_TOKEN"] = valid["access_token"]
existing["PI_REFRESH_TOKEN"] = valid["refresh_token"]

env_file.parent.mkdir(parents=True, exist_ok=True)
env_file.parent.chmod(0o700)

fd, temporary = tempfile.mkstemp(
    prefix=f".{env_file.name}.",
    dir=env_file.parent,
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        for key in sorted(existing):
            if allowed_key.fullmatch(key):
                handle.write(f"{key}={shlex.quote(existing[key])}\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, env_file)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass

# Confirm the new access token and Pi role without rotating the fresh refresh token again.
status, confirmed = post_json(
    bootstrap_url,
    {
        "action": "status",
        "execution_key": f"pi-local-auth-confirm-{uuid.uuid4()}",
        "correlation_id": "T4-FULL-RECOVERY-20260821",
    },
    {"authorization": f"Bearer {valid['access_token']}"},
)
if status != 200 or confirmed.get("ok") is not True:
    raise SystemExit("newly_stored_pi_session_verification_failed")

receipt.parent.mkdir(parents=True, exist_ok=True)
payload = {
    "receipt_type": "pi_auth_repair_20260821",
    "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "result": "repaired",
    "method": method,
    "source_path": str(source_path) if source_path else None,
    "candidate_count": len(deduped),
    "files_examined": len(unique_files),
    "env_file": str(env_file),
    "env_mode": "0600",
    "tokens_printed": False,
    "secret_values_included": False,
}
receipt.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
receipt.chmod(0o600)

print(
    "AUTH_REPAIR_OK "
    f"method={method} env={env_file} receipt={receipt}"
)
PY
then
  printf 'AUTH_REPAIR_STAGE=PASS\n'
else
  RC=$?
  printf 'AUTH_REPAIR_STAGE=BLOCKED exit_code=%s receipt=%s\n' \
    "$RC" "$AUTH_RECEIPT"
  printf 'NEXT=No valid local Supabase Pi session was found. Do not rerun the old dispatcher.\n'
  exit "$RC"
fi

printf '\n[3/6] 이전 실패 영수증 보존\n'

for path in "$FULL_RECEIPT" "$RESUME_RECEIPT" "$FINALIZER_RECEIPT"; do
  if [[ -f "$path" ]]; then
    mv "$path" "${path}.before-auth-repair-${STAMP}"
    chmod 600 "${path}.before-auth-repair-${STAMP}" 2>/dev/null || true
  fi
done

printf '\n[4/6] 검증된 전체 복구 디스패처 재실행\n'

rm -f "$DISPATCHER"

curl --fail --silent --show-error --location \
  --proto '=https' \
  --tlsv1.2 \
  --retry 2 \
  --retry-delay 2 \
  --connect-timeout 15 \
  --max-time 120 \
  "$DISPATCHER_URL" \
  -o "$DISPATCHER"

ACTUAL_BYTES="$(wc -c < "$DISPATCHER" | tr -d ' ')"
ACTUAL_SHA256="$(sha256sum "$DISPATCHER" | awk '{print $1}')"

[[ "$ACTUAL_BYTES" == "$DISPATCHER_BYTES" ]] || {
  printf 'DISPATCH_BLOCKED reason=byte_mismatch expected=%s actual=%s\n' \
    "$DISPATCHER_BYTES" "$ACTUAL_BYTES"
  exit 50
}

[[ "$ACTUAL_SHA256" == "$DISPATCHER_SHA256" ]] || {
  printf 'DISPATCH_BLOCKED reason=sha256_mismatch expected=%s actual=%s\n' \
    "$DISPATCHER_SHA256" "$ACTUAL_SHA256"
  exit 51
}

bash -n "$DISPATCHER"
chmod 700 "$DISPATCHER"

systemd-run --user \
  --unit="$UNIT" \
  --collect \
  --no-block \
  /usr/bin/bash "$DISPATCHER"

printf 'FULL_RECOVERY_REDISPATCHED unit=%s correlation=%s\n' \
  "$UNIT" "$CORRELATION_ID"

printf '\n[5/6] 완료 영수증 관측\n'

for ((attempt=1; attempt<=180; attempt++)); do
  if [[ -s "$FULL_RECEIPT" ]]; then
    break
  fi

  ACTIVE="$(
    systemctl --user show "$SERVICE" \
      --property=ActiveState \
      --value 2>/dev/null || true
  )"
  RESULT="$(
    systemctl --user show "$SERVICE" \
      --property=Result \
      --value 2>/dev/null || true
  )"

  if [[ "$ACTIVE" == "failed" || "$RESULT" == "failed" ]]; then
    break
  fi

  sleep 10
done

printf '\n[6/6] 안전한 최종 요약\n'

python3 - "$AUTH_RECEIPT" "$FULL_RECEIPT" "$RESUME_RECEIPT" "$FINALIZER_RECEIPT" <<'PY'
import json
import pathlib
import sys

labels = ("auth", "full", "resume", "finalizer")

for label, raw in zip(labels, sys.argv[1:]):
    path = pathlib.Path(raw)
    if not path.is_file():
        print(f"RECEIPT_{label.upper()}=MISSING path={path}")
        continue

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(
            f"RECEIPT_{label.upper()}=INVALID "
            f"path={path} error={type(exc).__name__}"
        )
        continue

    if data.get("secret_values_included") is True:
        print(f"RECEIPT_{label.upper()}=BLOCKED secret_boundary_failed")
        continue

    summary = {
        "result": data.get("result"),
        "blocker": data.get("blocker"),
        "correlation_id": data.get("correlation_id"),
        "primary": (
            data.get("after", {}).get("primary")
            if isinstance(data.get("after"), dict)
            else data.get("model", {}).get("primary")
            if isinstance(data.get("model"), dict)
            else None
        ),
        "fallbacks": (
            data.get("after", {}).get("fallbacks")
            if isinstance(data.get("after"), dict)
            else data.get("model", {}).get("fallbacks")
            if isinstance(data.get("model"), dict)
            else None
        ),
        "gateway_rpc_ok": (
            data.get("gateway_rpc_ok")
            if "gateway_rpc_ok" in data
            else data.get("gateway", {}).get("rpc")
            if isinstance(data.get("gateway"), dict)
            else None
        ),
        "telegram_outbound_sent": data.get("telegram_outbound_sent"),
        "resume_exit_code": data.get("resume_exit_code"),
        "finalizer_exit_code": data.get("finalizer_exit_code"),
    }

    print(
        f"RECEIPT_{label.upper()}=PRESENT "
        f"path={path} "
        f"summary={json.dumps(summary, ensure_ascii=False, separators=(',', ':'))}"
    )
PY

if [[ ! -s "$FULL_RECEIPT" ]]; then
  printf 'FULL_RECOVERY_PENDING_OR_FAILED unit=%s\n' "$SERVICE"
  printf 'CHECK_LOG=journalctl --user -u %s -n 160 --no-pager\n' "$SERVICE"
  exit 60
fi

printf '\n===== 기존 Telegram 봇에 각각 한 줄씩 전송 =====\n'
printf '/model default -s\n'
printf '/new\n'
printf '/status\n'
printf '%s\n' "$CORRELATION_ID"
printf '================================================\n'
OPENCLAW_PI_AUTH_REPAIR
