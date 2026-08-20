#!/usr/bin/env python3
"""Non-privileged OpenClaw reliability probe for Raspberry Pi and amd64 hosts.

The container performs outbound-only health checks. It does not poll Telegram,
start OpenClaw, mount the Docker socket, or receive provider credentials.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import platform
import re
import signal
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any

DEFAULT_SUPABASE_URL = "https://dpllasnpfskyyyzebyal.supabase.co"
DEFAULT_RECEIPT = "/data/openclaw-compat-receipt.json"
MAX_RESPONSE_BYTES = 256 * 1024
MAX_ERROR_CHARS = 160
TOKEN_LIKE = re.compile(
    r"(Bearer\s+[A-Za-z0-9._~-]{8,}|"
    r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|"
    r"tskey-[A-Za-z0-9_-]{8,}|"
    r"sk-[A-Za-z0-9_-]{16,})",
    re.IGNORECASE,
)

_STOP = False


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def redact(value: object) -> str:
    return TOKEN_LIKE.sub("[REDACTED]", str(value))[:MAX_ERROR_CHARS]


def atomic_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.parent.chmod(0o700)
    except PermissionError:
        pass
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def request_json(
    method: str,
    url: str,
    *,
    bearer: str = "",
    api_key: str = "",
    body: dict[str, Any] | None = None,
    timeout: int = 12,
) -> dict[str, Any]:
    headers = {
        "accept": "application/json",
        "user-agent": "openclaw-pi-compat/1",
    }
    if bearer:
        headers["authorization"] = f"Bearer {bearer}"
    if api_key:
        headers["apikey"] = api_key
    data = None
    if body is not None:
        headers["content-type"] = "application/json"
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(MAX_RESPONSE_BYTES)
            status = response.status
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            payload = {}
        return {
            "reachable": True,
            "status": status,
            "latency_ms": round((time.monotonic() - started) * 1000),
            "payload": payload if isinstance(payload, dict) else {},
            "error": None,
        }
    except urllib.error.HTTPError as error:
        error.read(4096)
        return {
            "reachable": True,
            "status": error.code,
            "latency_ms": round((time.monotonic() - started) * 1000),
            "payload": {},
            "error": f"http_{error.code}",
        }
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return {
            "reachable": False,
            "status": None,
            "latency_ms": round((time.monotonic() - started) * 1000),
            "payload": {},
            "error": redact(type(error).__name__),
        }


def safe_readiness(result: dict[str, Any]) -> dict[str, Any]:
    payload = result.get("payload") if isinstance(result.get("payload"), dict) else {}
    return {
        "configured": True,
        "reachable": result.get("reachable") is True,
        "status": result.get("status"),
        "latency_ms": result.get("latency_ms"),
        "state": payload.get("state"),
        "cloud_ready": payload.get("cloud_ready"),
        "physical_pi_complete": payload.get("physical_pi_complete"),
        "provider_secret_returned": payload.get("provider_secret_returned", False),
        "error": result.get("error"),
    }


def safe_queue(result: dict[str, Any]) -> dict[str, Any]:
    payload = result.get("payload") if isinstance(result.get("payload"), dict) else {}
    counts = payload.get("counts") if isinstance(payload.get("counts"), dict) else {}
    return {
        "configured": True,
        "reachable": result.get("reachable") is True,
        "status": result.get("status"),
        "latency_ms": result.get("latency_ms"),
        "counts": {str(key): int(value) for key, value in counts.items() if isinstance(value, int)},
        "server_secret_returned": payload.get("server_secret_returned", False),
        "error": result.get("error"),
    }


def safe_models(result: dict[str, Any]) -> dict[str, Any]:
    payload = result.get("payload") if isinstance(result.get("payload"), dict) else {}
    rows = payload.get("data") if isinstance(payload.get("data"), list) else []
    model_ids = [row.get("id") for row in rows if isinstance(row, dict) and isinstance(row.get("id"), str)]
    return {
        "configured": True,
        "reachable": result.get("reachable") is True,
        "status": result.get("status"),
        "latency_ms": result.get("latency_ms"),
        "model_ids": model_ids[:20],
        "provider_secret_returned": payload.get("provider_secret_returned", False),
        "error": result.get("error"),
    }


def safe_ollama(result: dict[str, Any]) -> dict[str, Any]:
    payload = result.get("payload") if isinstance(result.get("payload"), dict) else {}
    models = payload.get("models") if isinstance(payload.get("models"), list) else []
    names = [row.get("name") for row in models if isinstance(row, dict) and isinstance(row.get("name"), str)]
    return {
        "configured": True,
        "reachable": result.get("reachable") is True,
        "status": result.get("status"),
        "latency_ms": result.get("latency_ms"),
        "models": names[:20],
        "qwen25_3b_present": any(name.startswith("qwen2.5:3b") for name in names),
        "error": result.get("error"),
    }


def run_once() -> tuple[dict[str, Any], int]:
    supabase_url = os.environ.get("SUPABASE_URL", DEFAULT_SUPABASE_URL).rstrip("/")
    access_token = os.environ.get("PI_ACCESS_TOKEN", "").strip()
    publishable_key = os.environ.get("SUPABASE_PUBLISHABLE_KEY", "").strip()
    ollama_url = os.environ.get("OLLAMA_URL", "http://host.docker.internal:11434").rstrip("/")

    receipt: dict[str, Any] = {
        "schema_version": 1,
        "checked_at": utc_now(),
        "architecture": platform.machine(),
        "platform": sys.platform,
        "mode": "outbound_health_only",
        "single_telegram_poller_preserved": True,
        "provider_credentials_present": False,
        "provider_secret_returned": False,
        "paid_fallback_enabled": False,
        "docker_socket_required": False,
        "privileged_mode_required": False,
        "host_network_required": False,
    }

    if access_token:
        readiness_raw = request_json(
            "GET",
            f"{supabase_url}/functions/v1/openclaw-recovery-readiness",
            bearer=access_token,
            api_key=publishable_key,
        )
        queue_raw = request_json(
            "POST",
            f"{supabase_url}/functions/v1/pi-work-queue",
            bearer=access_token,
            api_key=publishable_key,
            body={"action": "status"},
        )
        models_raw = request_json(
            "GET",
            f"{supabase_url}/functions/v1/pi-model-gateway-guardian/v1/models",
            bearer=access_token,
            api_key=publishable_key,
        )
        receipt["readiness"] = safe_readiness(readiness_raw)
        receipt["queue"] = safe_queue(queue_raw)
        receipt["guardian_models"] = safe_models(models_raw)
    else:
        skipped = {"configured": False, "reason": "PI_ACCESS_TOKEN_missing"}
        receipt["readiness"] = skipped
        receipt["queue"] = skipped
        receipt["guardian_models"] = skipped

    ollama_raw = request_json("GET", f"{ollama_url}/api/tags", timeout=5)
    receipt["ollama"] = safe_ollama(ollama_raw)

    readiness_ok = receipt.get("readiness", {}).get("status") == 200
    ollama_ok = receipt.get("ollama", {}).get("status") == 200
    receipt["healthy"] = bool(readiness_ok or ollama_ok)
    receipt["secret_values_included"] = False

    receipt_path = pathlib.Path(os.environ.get("RECEIPT_PATH", DEFAULT_RECEIPT))
    atomic_json(receipt_path, receipt)
    print(json.dumps(receipt, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    return receipt, 0 if receipt["healthy"] else 2


def self_test() -> int:
    sample = "Bearer " + "A" * 24
    assert "A" * 24 not in redact(sample)
    assert redact("ordinary_error") == "ordinary_error"
    assert DEFAULT_SUPABASE_URL.startswith("https://")
    print(json.dumps({
        "ok": True,
        "self_test": "pass",
        "provider_credentials_present": False,
        "second_telegram_poller_created": False,
        "secret_values_included": False,
    }, separators=(",", ":"), sort_keys=True))
    return 0


def stop_handler(_signum: int, _frame: object) -> None:
    global _STOP
    _STOP = True


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true")
    mode.add_argument("--daemon", action="store_true")
    mode.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if not args.daemon:
        return run_once()[1]

    interval = max(30, min(int(os.environ.get("PROBE_INTERVAL_SECONDS", "120")), 3600))
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    last_exit = 0
    while not _STOP:
        _receipt, last_exit = run_once()
        for _ in range(interval):
            if _STOP:
                break
            time.sleep(1)
    return last_exit


if __name__ == "__main__":
    raise SystemExit(main())
