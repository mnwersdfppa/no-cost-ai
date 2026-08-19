#!/usr/bin/env python3
"""Fail-closed Raspberry Pi client for the Supabase/OpenClaw bridge.

The agent never receives a Supabase server key. It uses a short-lived Pi user JWT,
optionally refreshes that user session with the canonical publishable key, and
stores only public client configuration plus non-secret verification receipts.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any

BASE = os.environ.get("SUPABASE_URL", "https://dpllasnpfskyyyzebyal.supabase.co").rstrip("/")
TOKEN = os.environ.get("PI_ACCESS_TOKEN", "")
REFRESH_TOKEN = os.environ.get("PI_REFRESH_TOKEN", "")
PUBLISHABLE_KEY = os.environ.get("SUPABASE_PUBLISHABLE_KEY", "")
NODE_NAME = os.environ.get("OPENCLAW_BRIDGE_NODE_NAME", "raspberry-pi5")
ROOT = pathlib.Path(os.environ.get("OPENCLAW_ROOT", pathlib.Path.home() / ".openclaw"))
RUNTIME_DIR = pathlib.Path(os.environ.get("OPENCLAW_RUNTIME_DIR", ROOT / "runtime"))
SESSION_ENV = pathlib.Path(os.environ.get("SESSION_ENV_PATH", ROOT / "secrets" / "pi-work-queue.env"))
CANONICAL_CONFIG_PATH = pathlib.Path(os.environ.get("CANONICAL_CONFIG_PATH", RUNTIME_DIR / "canonical-client.json"))
CLIENT_ENV_PATH = pathlib.Path(os.environ.get("CANONICAL_CLIENT_ENV_PATH", RUNTIME_DIR / "supabase-client.env"))
TIMEOUT = 25


class BridgeError(RuntimeError):
    pass


def fail(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def atomic_write(path: pathlib.Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def read_env_file(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def write_session_values(access_token: str, refresh_token: str, publishable_key: str) -> None:
    values = read_env_file(SESSION_ENV)
    values.update(
        {
            "SUPABASE_URL": BASE,
            "PI_ACCESS_TOKEN": access_token,
            "PI_REFRESH_TOKEN": refresh_token,
            "SUPABASE_PUBLISHABLE_KEY": publishable_key,
            "OPENCLAW_BRIDGE_NODE_NAME": NODE_NAME,
            "OPENCLAW_RUNTIME_DIR": str(RUNTIME_DIR),
            "SESSION_ENV_PATH": str(SESSION_ENV),
            "CANONICAL_CONFIG_PATH": str(CANONICAL_CONFIG_PATH),
            "CANONICAL_CLIENT_ENV_PATH": str(CLIENT_ENV_PATH),
        }
    )
    content = "\n".join(f"{key}={values[key]}" for key in sorted(values)) + "\n"
    atomic_write(SESSION_ENV, content)


def refresh_session() -> bool:
    global TOKEN, REFRESH_TOKEN
    if not REFRESH_TOKEN or not PUBLISHABLE_KEY:
        return False
    body = json.dumps({"refresh_token": REFRESH_TOKEN}, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        f"{BASE}/auth/v1/token?grant_type=refresh_token",
        data=body,
        method="POST",
        headers={
            "apikey": PUBLISHABLE_KEY,
            "content-type": "application/json",
            "user-agent": "openclaw-bridge-agent/2",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            payload = json.load(response)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return False
    access = payload.get("access_token") if isinstance(payload, dict) else None
    refresh = payload.get("refresh_token") if isinstance(payload, dict) else None
    if not isinstance(access, str) or len(access) < 20:
        return False
    TOKEN = access
    if isinstance(refresh, str) and len(refresh) >= 20:
        REFRESH_TOKEN = refresh
    write_session_values(TOKEN, REFRESH_TOKEN, PUBLISHABLE_KEY)
    return True


def validate_contract(payload: dict[str, Any], contract: str) -> None:
    if payload.get("values_exposed") is not False:
        raise BridgeError("SECRET_BOUNDARY_NOT_CONFIRMED")
    if contract == "credential":
        for field in ("values_returned", "prefixes_returned", "hashes_returned", "lengths_returned"):
            if payload.get(field) is not False:
                raise BridgeError(f"CREDENTIAL_BOUNDARY_NOT_CONFIRMED:{field}")
    if contract == "canonical" and payload.get("server_secret_returned") is not False:
        raise BridgeError("SERVER_SECRET_BOUNDARY_NOT_CONFIRMED")


def request_json(path: str, body: dict[str, Any], contract: str = "bridge", retry_auth: bool = True) -> dict[str, Any]:
    if not BASE.startswith("https://"):
        raise BridgeError("HTTPS_SUPABASE_URL_REQUIRED")
    if len(TOKEN) < 20:
        raise BridgeError("CURRENT_SHORT_LIVED_PI_JWT_REQUIRED")
    encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        f"{BASE}/functions/v1/{path}",
        data=encoded,
        method="POST",
        headers={
            "authorization": f"Bearer {TOKEN}",
            "content-type": "application/json",
            "user-agent": "openclaw-bridge-agent/2",
            "x-correlation-id": str(body.get("correlation_id", "")),
            "x-execution-key": str(body.get("execution_key", "")),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        error.read(4096)
        if error.code == 401 and retry_auth and refresh_session():
            return request_json(path, body, contract=contract, retry_auth=False)
        if error.code in (401, 403):
            raise BridgeError(f"AUTH_OR_ROLE_REJECTED:HTTP_{error.code}") from error
        raise BridgeError(f"BRIDGE_REQUEST_REJECTED:HTTP_{error.code}") from error
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise BridgeError(f"BRIDGE_UNREACHABLE:{type(error).__name__}") from error
    if not isinstance(payload, dict):
        raise BridgeError("BRIDGE_INVALID_RESPONSE")
    validate_contract(payload, contract)
    return payload


def execution_key(prefix: str, bucket_seconds: int = 300) -> str:
    bucket = int(time.time() // bucket_seconds)
    return f"{prefix}-{NODE_NAME}-{bucket}"


def correlation_id() -> str:
    return str(uuid.uuid4())


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


def local_http_ok(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            return 200 <= response.status < 300
    except (urllib.error.URLError, TimeoutError):
        return False


def local_capabilities() -> dict[str, Any]:
    adb_devices = 0
    try:
        completed = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=5, check=False)
        if completed.returncode == 0:
            adb_devices = sum(1 for line in completed.stdout.splitlines()[1:] if line.strip().endswith("\tdevice"))
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return {
        "openclaw_cli": command_ok(["openclaw", "--version"]),
        "gateway_healthy": command_ok(["openclaw", "gateway", "status"]),
        "openclaw_status_healthy": command_ok(["openclaw", "status"]),
        "ollama_healthy": local_http_ok("http://127.0.0.1:11434/api/version"),
        "authorized_adb_devices": adb_devices,
        "paid_api_fallback_requested": False,
        "phone_write_requested": False,
        "telegram_poller_created": False,
    }


def canonical_config() -> dict[str, Any]:
    payload = request_json(
        "canonical-client-config",
        {
            "execution_key": execution_key("canonical-config", 21_600),
            "correlation_id": correlation_id(),
        },
        contract="canonical",
    )
    supabase = payload.get("supabase")
    if not isinstance(supabase, dict):
        raise BridgeError("CANONICAL_SUPABASE_CONFIG_MISSING")
    url = supabase.get("url")
    key = supabase.get("publishable_key")
    key_type = supabase.get("publishable_key_type")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise BridgeError("CANONICAL_SUPABASE_URL_INVALID")
    if not isinstance(key, str) or len(key) < 20 or key_type != "publishable":
        raise BridgeError("CANONICAL_PUBLISHABLE_KEY_INVALID")
    if supabase.get("legacy_anon_fallback_enabled") is not False:
        raise BridgeError("LEGACY_ANON_FALLBACK_MUST_BE_OFF")
    atomic_write(CANONICAL_CONFIG_PATH, json.dumps(payload, indent=2, sort_keys=True) + "\n")
    atomic_write(
        CLIENT_ENV_PATH,
        f"SUPABASE_URL={url}\nSUPABASE_PUBLISHABLE_KEY={key}\nSUPABASE_PROJECT_REF={supabase.get('project_ref', '')}\n",
    )
    global PUBLISHABLE_KEY
    PUBLISHABLE_KEY = key
    write_session_values(TOKEN, REFRESH_TOKEN, PUBLISHABLE_KEY)
    return payload


def heartbeat() -> dict[str, Any]:
    capabilities = local_capabilities()
    status = "online" if capabilities["gateway_healthy"] else "degraded"
    return request_json(
        "emergency-bridge",
        {
            "action": "heartbeat",
            "execution_key": execution_key("heartbeat"),
            "correlation_id": correlation_id(),
            "node_name": NODE_NAME,
            "node_type": "raspberry_pi",
            "status": status,
            "capabilities": capabilities,
            "metadata": {"source": "openclaw-bridge-agent", "secret_values_included": False},
        },
    )


def bridge_status() -> dict[str, Any]:
    return request_json(
        "emergency-bridge",
        {"action": "status", "execution_key": execution_key("status", 60), "correlation_id": correlation_id()},
    )


def policy(provider: str = "openai", operation: str = "chat") -> dict[str, Any]:
    return request_json(
        "emergency-bridge",
        {
            "action": "policy_check",
            "execution_key": execution_key(f"policy-{provider}-{operation}", 60),
            "correlation_id": correlation_id(),
            "integration": provider,
            "operation": operation,
        },
    )


def route(capability: str = "model_chat", risk_tier: int = 0) -> dict[str, Any]:
    return request_json(
        "emergency-bridge",
        {
            "action": "resolve_route",
            "execution_key": execution_key(f"route-{capability}-{risk_tier}", 60),
            "correlation_id": correlation_id(),
            "capability": capability,
            "risk_tier": risk_tier,
        },
    )


def queue_status() -> dict[str, Any]:
    return request_json(
        "emergency-bridge",
        {"action": "queue_status", "execution_key": execution_key("queue-status", 60), "correlation_id": correlation_id()},
    )


def credential_readiness() -> dict[str, Any]:
    return request_json(
        "credential-readiness",
        {"execution_key": execution_key("credential-readiness", 86_400), "correlation_id": correlation_id()},
        contract="credential",
    )


def command_status() -> dict[str, Any]:
    return request_json(
        "command-center",
        {"action": "command_status", "execution_key": execution_key("command-status", 60), "correlation_id": correlation_id()},
    )


def controls_from_status(payload: dict[str, Any]) -> dict[str, bool]:
    controls = payload.get("controls")
    if not isinstance(controls, list):
        raise BridgeError("STATUS_CONTROLS_MISSING")
    return {
        str(row.get("control_key")): bool(row.get("enabled"))
        for row in controls
        if isinstance(row, dict) and isinstance(row.get("control_key"), str)
    }


def verify_all() -> dict[str, Any]:
    config = canonical_config()
    heartbeat_payload = heartbeat()
    credentials = credential_readiness()
    command = command_status()
    policy_payload = policy()
    queue = queue_status()
    route_payload = route()
    status_payload = bridge_status()

    decision = policy_payload.get("decision")
    if not isinstance(decision, dict) or decision.get("allowed") is not False or decision.get("reason") != "paid_api_fallback_disabled":
        raise BridgeError("PAID_OPENAI_POLICY_NOT_DENIED")

    controls = controls_from_status(status_payload)
    required_controls = {
        "supabase_control_plane": True,
        "paid_api_fallback": False,
        "external_write_actions": False,
        "phone_write_actions": False,
        "public_shell_execution": False,
        "telegram_single_poller_enforced": True,
        "vercel_raw_token_fallback": False,
        "vercel_deployments": False,
        "modern_server_key_unification_verified": True,
    }
    for key, expected in required_controls.items():
        if controls.get(key) is not expected:
            raise BridgeError(f"CONTROL_MISMATCH:{key}")

    local = local_capabilities()
    route_record = route_payload.get("route")
    if not isinstance(route_record, dict):
        raise BridgeError("ROUTE_DECISION_MISSING")
    if local["ollama_healthy"] and route_record.get("route_key") != "ollama.local":
        raise BridgeError("LOCAL_OLLAMA_NOT_SELECTED")
    if route_record.get("integration") == "openai":
        raise BridgeError("PAID_OPENAI_ROUTE_SELECTED")

    result = {
        "result": "verified",
        "node": NODE_NAME,
        "canonical_config": bool(config.get("ok")),
        "heartbeat": bool(heartbeat_payload.get("ok")),
        "credential_readiness": bool(credentials.get("ok")),
        "command_status": bool(command.get("ok")),
        "paid_openai_denied": True,
        "queue_status": bool(queue.get("ok")),
        "route_decision": route_record.get("decision"),
        "route_key": route_record.get("route_key"),
        "local_ollama_healthy": local["ollama_healthy"],
        "modern_server_key_unification_verified": True,
        "telegram_single_poller_enforced": True,
        "secret_values_printed": False,
    }
    atomic_write(RUNTIME_DIR / "bridge-verification-receipt.json", json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, separators=(",", ":"), sort_keys=True))


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "verify"
    try:
        if action == "config": emit({"ok": bool(canonical_config().get("ok"))})
        elif action == "heartbeat": emit({"ok": bool(heartbeat().get("ok"))})
        elif action == "status": emit(bridge_status())
        elif action == "credentials": emit(credential_readiness())
        elif action == "command-status": emit(command_status())
        elif action == "policy": emit(policy(sys.argv[2] if len(sys.argv) > 2 else "openai", sys.argv[3] if len(sys.argv) > 3 else "chat"))
        elif action == "route": emit(route(sys.argv[2] if len(sys.argv) > 2 else "model_chat", int(sys.argv[3]) if len(sys.argv) > 3 else 0))
        elif action == "queue": emit(queue_status())
        elif action == "verify": emit(verify_all())
        else: fail("SUPPORTED_ACTIONS=config|heartbeat|status|credentials|command-status|policy|route|queue|verify", 2)
    except BridgeError as error:
        fail(f"BLOCKED={error}", 40)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
