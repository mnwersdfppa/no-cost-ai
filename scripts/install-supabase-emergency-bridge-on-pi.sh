#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$ROOT/secrets/pi-work-queue.env}"
BIN_DIR="$ROOT/bin"
UNIT_DIR="$HOME/.config/systemd/user"
CLIENT="$BIN_DIR/openclaw-emergency-bridge"

for command in python3 systemctl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "BLOCKED=MISSING_COMMAND:$command" >&2
    exit 20
  }
done

[[ -r "$ENV_FILE" ]] || {
  echo "BLOCKED=PI_ENV_FILE_MISSING:$ENV_FILE" >&2
  exit 21
}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

SUPABASE_URL="${SUPABASE_URL:-https://dpllasnpfskyyyzebyal.supabase.co}"
PI_ACCESS_TOKEN="${PI_ACCESS_TOKEN:-}"
[[ "$SUPABASE_URL" == https://* ]] || {
  echo 'BLOCKED=HTTPS_SUPABASE_URL_REQUIRED' >&2
  exit 22
}
[[ ${#PI_ACCESS_TOKEN} -ge 20 ]] || {
  echo 'BLOCKED=CURRENT_SHORT_LIVED_PI_JWT_REQUIRED' >&2
  exit 23
}

mkdir -p "$ROOT" "$ROOT/secrets" "$BIN_DIR" "$UNIT_DIR"
chmod 700 "$ROOT" "$ROOT/secrets" "$BIN_DIR"
chmod 600 "$ENV_FILE"

cat > "$CLIENT" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from typing import Any

BASE = os.environ.get("SUPABASE_URL", "").rstrip("/")
TOKEN = os.environ.get("PI_ACCESS_TOKEN", "")
NODE_NAME = os.environ.get("OPENCLAW_BRIDGE_NODE_NAME", "raspberry-pi5")
TIMEOUT = 20


def fail(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def command_ok(command: list[str], timeout: int = 8) -> bool:
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
            env={**os.environ, "NO_COLOR": "1"},
        )
        return completed.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def local_capabilities() -> dict[str, Any]:
    adb_devices = 0
    try:
        result = subprocess.run(
            ["adb", "devices"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if result.returncode == 0:
            adb_devices = sum(
                1
                for line in result.stdout.splitlines()[1:]
                if line.strip().endswith("\tdevice")
            )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return {
        "openclaw_cli": command_ok(["openclaw", "--version"]),
        "gateway_healthy": command_ok(["openclaw", "gateway", "status"]),
        "openclaw_status_healthy": command_ok(["openclaw", "status"]),
        "ollama_healthy": command_ok(
            ["curl", "-fsS", "--max-time", "3", "http://127.0.0.1:11434/api/version"]
        ),
        "authorized_adb_devices": adb_devices,
        "paid_api_fallback_requested": False,
        "phone_write_requested": False,
        "telegram_poller_created": False,
    }


def request(path: str, body: dict[str, Any]) -> dict[str, Any]:
    if not BASE.startswith("https://"):
        fail("BLOCKED=HTTPS_SUPABASE_URL_REQUIRED", 20)
    if len(TOKEN) < 20:
        fail("BLOCKED=PI_ACCESS_TOKEN_REQUIRED", 21)

    encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        f"{BASE}/functions/v1/{path}",
        data=encoded,
        method="POST",
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "openclaw-emergency-bridge-pi/1",
            "X-Correlation-Id": str(body.get("correlation_id", "")),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        exc.read(4096)
        if exc.code in (401, 403):
            fail(f"AUTH_OR_ROLE_REJECTED=HTTP_{exc.code}", 30)
        fail(f"BRIDGE_REQUEST_REJECTED=HTTP_{exc.code}", 31)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        fail(f"BRIDGE_UNREACHABLE={type(exc).__name__}", 32)

    if not isinstance(payload, dict):
        fail("BRIDGE_INVALID_RESPONSE", 33)
    if payload.get("values_exposed") is not False:
        fail("BRIDGE_SECRET_BOUNDARY_NOT_CONFIRMED", 34)
    return payload


def execution_key(prefix: str) -> str:
    bucket = int(time.time() // 300)
    return f"{prefix}-{NODE_NAME}-{bucket}"


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    correlation_id = str(uuid.uuid4())

    if action == "heartbeat":
        capabilities = local_capabilities()
        status = "online" if capabilities["gateway_healthy"] else "degraded"
        payload = request(
            "emergency-bridge",
            {
                "action": "heartbeat",
                "execution_key": execution_key("heartbeat"),
                "correlation_id": correlation_id,
                "node_name": NODE_NAME,
                "node_type": "raspberry_pi",
                "status": status,
                "capabilities": capabilities,
                "metadata": {
                    "source": "systemd_user_timer",
                    "secret_values_included": False,
                },
            },
        )
        print(f"HEARTBEAT=PASS status={status} duplicate={bool(payload.get('duplicate'))}")
        return 0

    if action == "status":
        payload = request(
            "emergency-bridge",
            {
                "action": "status",
                "execution_key": f"status-{uuid.uuid4()}",
                "correlation_id": correlation_id,
            },
        )
        controls = {
            row.get("control_key"): row.get("enabled")
            for row in payload.get("controls", [])
            if isinstance(row, dict)
        }
        required = {
            "paid_api_fallback": False,
            "public_shell_execution": False,
            "telegram_single_poller_enforced": True,
            "supabase_control_plane": True,
        }
        for key, expected in required.items():
            if controls.get(key) is not expected:
                fail(f"STATUS_CONTROL_MISMATCH={key}", 40)
        print("STATUS=PASS paid_api_fallback=OFF public_shell=OFF single_poller=ON")
        return 0

    if action == "queue":
        payload = request(
            "emergency-bridge",
            {
                "action": "queue_status",
                "execution_key": f"queue-{uuid.uuid4()}",
                "correlation_id": correlation_id,
            },
        )
        print("QUEUE_STATUS=PASS counts=" + json.dumps(payload.get("counts", {}), separators=(",", ":")))
        return 0

    if action == "policy":
        provider = sys.argv[2] if len(sys.argv) > 2 else "openai"
        operation = sys.argv[3] if len(sys.argv) > 3 else "chat"
        payload = request(
            "emergency-bridge",
            {
                "action": "policy_check",
                "execution_key": f"policy-{uuid.uuid4()}",
                "correlation_id": correlation_id,
                "integration": provider,
                "operation": operation,
            },
        )
        decision = payload.get("decision", {})
        print(
            "POLICY=PASS "
            + json.dumps(
                {
                    "integration": provider,
                    "operation": operation,
                    "allowed": decision.get("allowed"),
                    "approval_required": decision.get("approval_required"),
                    "reason": decision.get("reason"),
                },
                separators=(",", ":"),
            )
        )
        return 0

    if action == "credentials":
        payload = request(
            "credential-readiness",
            {
                "correlation_id": correlation_id,
            },
        )
        if payload.get("values_returned") is not False:
            fail("CREDENTIAL_VALUE_BOUNDARY_NOT_CONFIRMED", 50)
        present = [
            row.get("integration")
            for row in payload.get("results", [])
            if isinstance(row, dict) and row.get("present_in_edge_runtime") is True
        ]
        print("CREDENTIAL_READINESS=PASS present_integrations=" + json.dumps(present, separators=(",", ":")))
        return 0

    fail("SUPPORTED_ACTIONS=status|heartbeat|queue|policy|credentials", 2)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
PY

chmod 700 "$CLIENT"

cat > "$UNIT_DIR/openclaw-emergency-heartbeat.service" <<EOF
[Unit]
Description=OpenClaw Supabase emergency bridge heartbeat
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/env python3 $CLIENT heartbeat
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
TimeoutStartSec=45
EOF

cat > "$UNIT_DIR/openclaw-emergency-heartbeat.timer" <<'EOF'
[Unit]
Description=Send OpenClaw emergency heartbeat every five minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30
Persistent=true
Unit=openclaw-emergency-heartbeat.service

[Install]
WantedBy=timers.target
EOF

cat > "$UNIT_DIR/openclaw-credential-readiness.service" <<EOF
[Unit]
Description=Refresh non-secret OpenClaw credential readiness
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/env python3 $CLIENT credentials
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
TimeoutStartSec=45
EOF

cat > "$UNIT_DIR/openclaw-credential-readiness.timer" <<'EOF'
[Unit]
Description=Refresh OpenClaw credential readiness daily

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
RandomizedDelaySec=5min
Persistent=true
Unit=openclaw-credential-readiness.service

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload

# A real authenticated status test must pass before timers are enabled.
"$CLIENT" status
"$CLIENT" policy openai chat
"$CLIENT" queue

systemctl --user enable --now openclaw-emergency-heartbeat.timer
systemctl --user enable --now openclaw-credential-readiness.timer
systemctl --user start openclaw-emergency-heartbeat.service

printf '%s\n' \
  'RESULT=SUPABASE_EMERGENCY_BRIDGE_PI_READY' \
  'HEARTBEAT_TIMER=ENABLED_5_MINUTES' \
  'CREDENTIAL_READINESS_TIMER=ENABLED_DAILY' \
  'PAID_API_FALLBACK=OFF' \
  'PUBLIC_SHELL=OFF' \
  'SECOND_TELEGRAM_POLLER=OFF' \
  "MANUAL_STATUS=$CLIENT status" \
  "ROLLBACK=systemctl --user disable --now openclaw-emergency-heartbeat.timer openclaw-credential-readiness.timer"
