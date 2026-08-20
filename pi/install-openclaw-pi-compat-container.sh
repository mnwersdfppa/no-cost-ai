#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
BIN_DIR="$ROOT/bin"
SECRETS_DIR="$ROOT/secrets"
RUNTIME_DIR="$ROOT/runtime"
SESSION_ENV="${PI_WORK_QUEUE_ENV:-$SECRETS_DIR/pi-work-queue.env}"
REFRESH_HELPER="$BIN_DIR/refresh-pi-supabase-session"
RUNNER="$BIN_DIR/openclaw-pi-compat-run"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE="$UNIT_DIR/openclaw-pi-compat.service"
TIMER="$UNIT_DIR/openclaw-pi-compat.timer"
RECEIPT="$RUNTIME_DIR/openclaw-pi-compat-install-receipt.json"
VOLUME="openclaw-pi-compat-data"
CONFIG_PATH="openclaw-pi-compat-config"
BACKUP_DIR="$(mktemp -d "$RUNTIME_DIR/.pi-compat-backup.XXXXXX")"
TMP="$(mktemp -d "$RUNTIME_DIR/.pi-compat-install.XXXXXX")"
COMMITTED=0

log() { printf '%s\n' "$*"; }
fail() { printf 'BLOCKED=%s\n' "$1" >&2; exit "${2:-1}"; }

cleanup() {
  local code=$?
  if [[ "$code" -ne 0 && "$COMMITTED" -ne 1 ]]; then
    systemctl --user disable --now openclaw-pi-compat.timer >/dev/null 2>&1 || true
    rm -f -- "$RUNNER" "$SERVICE" "$TIMER"
    for name in runner service timer; do
      if [[ -f "$BACKUP_DIR/$name" ]]; then
        case "$name" in
          runner) cp -a -- "$BACKUP_DIR/$name" "$RUNNER" ;;
          service) cp -a -- "$BACKUP_DIR/$name" "$SERVICE" ;;
          timer) cp -a -- "$BACKUP_DIR/$name" "$TIMER" ;;
        esac
      fi
    done
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TMP" "$BACKUP_DIR"
  exit "$code"
}
trap cleanup EXIT

for command in bash curl docker python3 systemctl; do
  command -v "$command" >/dev/null 2>&1 || fail "missing_$command" 40
done

docker info >/dev/null 2>&1 || fail "docker_daemon_unavailable" 41
[[ -f "$SESSION_ENV" ]] || fail "pi_session_env_missing" 42
[[ -x "$REFRESH_HELPER" ]] || fail "pi_refresh_helper_missing_run_base_recovery_first" 43

mkdir -p "$BIN_DIR" "$SECRETS_DIR" "$RUNTIME_DIR" "$UNIT_DIR"
chmod 700 "$BIN_DIR" "$SECRETS_DIR" "$RUNTIME_DIR" "$UNIT_DIR"
[[ -f "$RUNNER" ]] && cp -a -- "$RUNNER" "$BACKUP_DIR/runner"
[[ -f "$SERVICE" ]] && cp -a -- "$SERVICE" "$BACKUP_DIR/service"
[[ -f "$TIMER" ]] && cp -a -- "$TIMER" "$BACKUP_DIR/timer"

"$REFRESH_HELPER" >/dev/null 2>&1 || fail "pi_session_refresh_failed" 44

python3 - "$SESSION_ENV" "$TMP/session.json" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
allowed = {
    "SUPABASE_URL",
    "PI_ACCESS_TOKEN",
    "SUPABASE_PUBLISHABLE_KEY",
    "OLLAMA_URL",
}
values = {}
for raw in source.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    key = key.strip()
    if key in allowed:
        values[key] = value.strip()
destination.write_text(json.dumps(values), encoding="utf-8")
destination.chmod(0o600)
PY

SUPABASE_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("SUPABASE_URL",""))' "$TMP/session.json")"
PI_ACCESS_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("PI_ACCESS_TOKEN",""))' "$TMP/session.json")"
SUPABASE_PUBLISHABLE_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("SUPABASE_PUBLISHABLE_KEY",""))' "$TMP/session.json")"
[[ "$SUPABASE_URL" == https://* ]] || fail "https_supabase_url_required" 45
(( ${#PI_ACCESS_TOKEN} >= 20 )) || fail "pi_access_token_missing_after_refresh" 46

headers=(-H "authorization: Bearer $PI_ACCESS_TOKEN" -H "accept: application/json" -H "user-agent: openclaw-pi-compat-installer/1")
if [[ -n "$SUPABASE_PUBLISHABLE_KEY" ]]; then
  headers+=(-H "apikey: $SUPABASE_PUBLISHABLE_KEY")
fi
curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 45 \
  "${headers[@]}" \
  -o "$TMP/config.json" \
  "$SUPABASE_URL/functions/v1/$CONFIG_PATH"

IMAGE_REF="$(python3 - "$TMP/config.json" <<'PY'
import json
import re
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
ref = value.get("immutable_ref")
assert value.get("ok") is True
assert value.get("state") == "ready"
assert isinstance(ref, str)
assert re.fullmatch(r"ghcr\.io/mnwersdfppa/openclaw-pi-compat@sha256:[0-9a-f]{64}", ref)
assert value.get("native_openclaw_remains_canonical") is True
assert value.get("selected_by_default") is False
assert value.get("provider_credentials_required") is False
assert value.get("supabase_service_role_required") is False
assert value.get("telegram_token_required") is False
assert value.get("second_telegram_poller_created") is False
assert value.get("paid_fallback_enabled") is False
policy = value.get("run_policy") or {}
assert policy.get("read_only") is True
assert policy.get("user") == "10001:10001"
assert policy.get("privileged") is False
assert policy.get("host_network") is False
assert policy.get("docker_socket") is False
print(ref)
PY
)" || fail "compat_config_contract_failed" 47

docker pull "$IMAGE_REF" >/dev/null

docker image inspect "$IMAGE_REF" > "$TMP/image.json"
python3 - "$TMP/image.json" <<'PY'
import json
import sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(rows) == 1
row = rows[0]
assert row.get("Architecture") in {"arm64", "amd64"}
config = row.get("Config") or {}
assert config.get("User") == "10001:10001"
assert (config.get("Healthcheck") or {}).get("Test")
assert not config.get("ExposedPorts")
PY

docker run --rm \
  --read-only \
  --network none \
  --user 10001:10001 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:size=16m,mode=1777 \
  --env OPENCLAW_COMPAT_MODE=self-test \
  "$IMAGE_REF" >/dev/null

docker volume create "$VOLUME" >/dev/null

cat > "$RUNNER" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
SESSION_ENV="${PI_WORK_QUEUE_ENV:-$ROOT/secrets/pi-work-queue.env}"
REFRESH_HELPER="$ROOT/bin/refresh-pi-supabase-session"
RUNTIME_DIR="$ROOT/runtime"
IMAGE_REF_FILE="$RUNTIME_DIR/openclaw-pi-compat-image-ref"
VOLUME="openclaw-pi-compat-data"

[[ -f "$SESSION_ENV" ]] || exit 0
[[ -f "$IMAGE_REF_FILE" ]] || exit 0
[[ -x "$REFRESH_HELPER" ]] && "$REFRESH_HELPER" >/dev/null 2>&1 || true

mapfile -t env_lines < <(python3 - "$SESSION_ENV" <<'PY'
import pathlib
import sys
allowed = {"SUPABASE_URL", "PI_ACCESS_TOKEN", "SUPABASE_PUBLISHABLE_KEY", "OLLAMA_URL"}
values = {}
for raw in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.strip() in allowed:
        values[key.strip()] = value.strip()
for key in sorted(values):
    print(f"{key}={values[key]}")
PY
)
for line in "${env_lines[@]}"; do export "$line"; done

SUPABASE_URL="${SUPABASE_URL:-}"
PI_ACCESS_TOKEN="${PI_ACCESS_TOKEN:-}"
SUPABASE_PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY:-}"
OLLAMA_URL="${OLLAMA_URL:-http://host.docker.internal:11434}"
IMAGE_REF="$(<"$IMAGE_REF_FILE")"
[[ "$IMAGE_REF" =~ ^ghcr\.io/mnwersdfppa/openclaw-pi-compat@sha256:[0-9a-f]{64}$ ]] || exit 0

env_args=(-e "SUPABASE_URL" -e "OLLAMA_URL")
[[ -n "$PI_ACCESS_TOKEN" ]] && env_args+=(-e "PI_ACCESS_TOKEN")
[[ -n "$SUPABASE_PUBLISHABLE_KEY" ]] && env_args+=(-e "SUPABASE_PUBLISHABLE_KEY")

docker run --rm \
  --pull never \
  --read-only \
  --user 10001:10001 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:size=16m,mode=1777 \
  --add-host host.docker.internal:host-gateway \
  --mount type=volume,src="$VOLUME",dst=/data \
  "${env_args[@]}" \
  "$IMAGE_REF"
RUNNER
chmod 700 "$RUNNER"

printf '%s\n' "$IMAGE_REF" > "$RUNTIME_DIR/openclaw-pi-compat-image-ref"
chmod 600 "$RUNTIME_DIR/openclaw-pi-compat-image-ref"

cat > "$SERVICE" <<EOF
[Unit]
Description=OpenClaw optional outbound compatibility probe
After=docker.service network-online.target openclaw-pi-session-refresh.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RUNNER
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
LockPersonality=true
RestrictSUIDSGID=true
UMask=0077

[Install]
WantedBy=default.target
EOF

cat > "$TIMER" <<'EOF'
[Unit]
Description=Schedule OpenClaw optional compatibility probe

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true
Unit=openclaw-pi-compat.service

[Install]
WantedBy=timers.target
EOF
chmod 600 "$SERVICE" "$TIMER"

systemctl --user daemon-reload
systemctl --user enable --now openclaw-pi-compat.timer
systemctl --user start openclaw-pi-compat.service || true

python3 - "$RECEIPT" "$IMAGE_REF" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

path = pathlib.Path(sys.argv[1])
image = sys.argv[2]
path.write_text(json.dumps({
    "result": "installed",
    "installed_at": datetime.now(timezone.utc).isoformat(),
    "immutable_ref": image,
    "mode": "optional_outbound_diagnostic",
    "timer": "openclaw-pi-compat.timer",
    "interval": "5min+jitter",
    "native_openclaw_remains_canonical": True,
    "provider_credentials_included": False,
    "supabase_service_role_included": False,
    "telegram_token_included": False,
    "second_telegram_poller_created": False,
    "paid_fallback_enabled": False,
    "privileged_mode": False,
    "host_network": False,
    "docker_socket_mounted_into_container": False,
    "secret_values_included": False,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
path.chmod(0o600)
PY

COMMITTED=1
log "RESULT=installed component=openclaw-pi-compat image=$IMAGE_REF receipt=$RECEIPT"
