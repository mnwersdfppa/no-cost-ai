#!/usr/bin/env python3
"""Deterministic Raspberry Pi recovery worker for the Supabase/OpenClaw queue.

This worker deliberately does not execute arbitrary commands from queue payloads.
It claims only server-side allowlisted recovery task types and maps each task to
pinned, locally implemented behavior.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any

ROOT = pathlib.Path(os.environ.get("OPENCLAW_ROOT", pathlib.Path.home() / ".openclaw"))
SECRETS_DIR = ROOT / "secrets"
RUNTIME_DIR = pathlib.Path(os.environ.get("OPENCLAW_RUNTIME_DIR", ROOT / "runtime"))
SESSION_ENV = pathlib.Path(os.environ.get("PI_WORK_QUEUE_ENV", SECRETS_DIR / "pi-work-queue.env"))
LOCK_FILE = RUNTIME_DIR / "openclaw-recovery-queue.lock"
RECEIPT_FILE = RUNTIME_DIR / "openclaw-recovery-queue-receipt.json"
TIMEOUT = 30
MAX_DOWNLOAD_BYTES = 1_000_000
CANONICAL_INSTALLER_URL = (
    "https://dpllasnpfskyyyzebyal.supabase.co/"
    "functions/v1/pi-recovery-installer-verified"
)
CANONICAL_INSTALLER_SHA256 = "4c21d9eab6fff335950f8a4c8c7a064a20b9aa00aead487b811cee779e8ae947"
PINNED_OLLAMA_REPAIR_URL = (
    "https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/"
    "2c073a8e3ba70a78e2afe3494bde2761ec1f2d5e/"
    "pi/recover-openclaw-telegram-models.sh"
)
PINNED_OLLAMA_REPAIR_SHA256 = "61080114abc37c4bb78aaa9abee22b64848772f9c15f62784d5618b1ec7083cb"
ALLOWED_TASK_TYPES = frozenset(
    {
        "pi_supabase_auth_model_recovery",
        "telegram_model_failover_repair",
        "worker_liveness_guardian",
    }
)
SECRET_PATTERN = re.compile(
    r"(sk-proj-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|"
    r"xox[baprs]-[A-Za-z0-9-]+|tskey-[A-Za-z0-9_-]+|"
    r"Bearer\s+[A-Za-z0-9._~-]{16,}|"
    r"-----BEGIN (?:RSA|OPENSSH|EC) PRIVATE KEY-----)",
    re.IGNORECASE,
)


class RecoveryError(RuntimeError):
    pass


def redact(value: str, limit: int = 2000) -> str:
    return SECRET_PATTERN.sub("[REDACTED]", value).replace("\x00", "")[:limit]


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


def read_env(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


ENV = read_env(SESSION_ENV)
BASE = (os.environ.get("SUPABASE_URL") or ENV.get("SUPABASE_URL") or "").rstrip("/")
ACCESS_TOKEN = os.environ.get("PI_ACCESS_TOKEN") or ENV.get("PI_ACCESS_TOKEN") or ""
REFRESH_TOKEN = os.environ.get("PI_REFRESH_TOKEN") or ENV.get("PI_REFRESH_TOKEN") or ""


def write_session(access: str, refresh: str) -> None:
    global ACCESS_TOKEN, REFRESH_TOKEN
    values = read_env(SESSION_ENV)
    values["SUPABASE_URL"] = BASE
    values["PI_ACCESS_TOKEN"] = access
    values["PI_REFRESH_TOKEN"] = refresh
    values.setdefault("OPENCLAW_ROOT", str(ROOT))
    values.setdefault("OPENCLAW_RUNTIME_DIR", str(RUNTIME_DIR))
    atomic_write(SESSION_ENV, "\n".join(f"{key}={values[key]}" for key in sorted(values)) + "\n")
    ACCESS_TOKEN = access
    REFRESH_TOKEN = refresh


def json_request(
    url: str,
    body: dict[str, Any],
    *,
    token: str | None = None,
    timeout: int = TIMEOUT,
) -> tuple[int, dict[str, Any]]:
    payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
    headers = {
        "content-type": "application/json",
        "user-agent": "openclaw-recovery-queue-worker/1",
    }
    if token:
        headers["authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, data=payload, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.load(response)
            return response.status, data if isinstance(data, dict) else {}
    except urllib.error.HTTPError as error:
        raw = error.read(4096)
        try:
            data = json.loads(raw.decode("utf-8", errors="replace"))
        except json.JSONDecodeError:
            data = {}
        return error.code, data if isinstance(data, dict) else {}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise RecoveryError(f"network_failure:{type(error).__name__}") from error


def refresh_session() -> bool:
    if not BASE.startswith("https://") or len(REFRESH_TOKEN) < 20:
        return False
    status, data = json_request(
        f"{BASE}/functions/v1/pi-auth-refresh",
        {"refresh_token": REFRESH_TOKEN},
        timeout=20,
    )
    if status != 200 or data.get("ok") is not True:
        return False
    access = data.get("access_token")
    refresh = data.get("refresh_token")
    if not isinstance(access, str) or len(access) < 20:
        return False
    if not isinstance(refresh, str) or len(refresh) < 20:
        refresh = REFRESH_TOKEN
    write_session(access, refresh)
    return True


def queue_request(body: dict[str, Any], retry_auth: bool = True) -> dict[str, Any]:
    if not BASE.startswith("https://"):
        raise RecoveryError("https_supabase_url_required")
    if len(ACCESS_TOKEN) < 20 and not refresh_session():
        raise RecoveryError("pi_session_refresh_required")
    status, data = json_request(
        f"{BASE}/functions/v1/pi-work-queue",
        body,
        token=ACCESS_TOKEN,
        timeout=35,
    )
    if status == 401 and retry_auth and refresh_session():
        return queue_request(body, retry_auth=False)
    if status != 200 or data.get("ok") is not True:
        error = data.get("error") if isinstance(data.get("error"), str) else f"http_{status}"
        raise RecoveryError(f"queue_request_failed:{error}")
    if data.get("values_exposed") is not False or data.get("server_secret_returned") is not False:
        raise RecoveryError("queue_secret_boundary_not_confirmed")
    return data


def run_command(command: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env={**os.environ, "NO_COLOR": "1"},
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as error:
        raise RecoveryError(f"command_failed:{command[0]}:{type(error).__name__}") from error


def command_ok(command: list[str], timeout: int = 20) -> bool:
    try:
        return run_command(command, timeout).returncode == 0
    except RecoveryError:
        return False


def download_verified(url: str, expected_sha256: str, allowed_url: str) -> pathlib.Path:
    if url != allowed_url or not url.startswith("https://"):
        raise RecoveryError("unapproved_download_url")
    request = urllib.request.Request(url, headers={"user-agent": "openclaw-recovery-queue-worker/1"})
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            data = response.read(MAX_DOWNLOAD_BYTES + 1)
    except (urllib.error.URLError, TimeoutError) as error:
        raise RecoveryError(f"download_failed:{type(error).__name__}") from error
    if len(data) > MAX_DOWNLOAD_BYTES:
        raise RecoveryError("download_too_large")
    observed = hashlib.sha256(data).hexdigest()
    if observed != expected_sha256:
        raise RecoveryError("download_sha256_mismatch")
    fd, path = tempfile.mkstemp(prefix="openclaw-recovery-", suffix=".sh", dir=RUNTIME_DIR)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, 0o700)
    return pathlib.Path(path)


def safe_receipt(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists() or path.stat().st_size > 64_000:
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict) or data.get("secret_values_included") is not False:
        return {}
    allowed = {
        "result",
        "primary",
        "fallbacks",
        "utility_model",
        "provider_secret_location",
        "pi_credential",
        "pi_token_refresh_timer",
        "tailscale",
        "gateway_unit",
        "next_telegram_action",
        "paid_fallback_enabled",
        "second_telegram_poller_created",
        "verified_at",
        "model",
        "agent",
        "ollama_endpoint",
        "provider_api",
        "fallback_installed",
        "primary_preserved",
    }
    return {key: data[key] for key in allowed if key in data}


def handle_model_recovery(task: dict[str, Any]) -> dict[str, Any]:
    payload = task.get("payload") if isinstance(task.get("payload"), dict) else {}
    url = payload.get("installer_url")
    digest = payload.get("installer_sha256")
    if url != CANONICAL_INSTALLER_URL or digest != CANONICAL_INSTALLER_SHA256:
        raise RecoveryError("canonical_installer_contract_mismatch")
    script = download_verified(str(url), str(digest), CANONICAL_INSTALLER_URL)
    try:
        completed = run_command(["/usr/bin/env", "bash", str(script)], timeout=1200)
    finally:
        script.unlink(missing_ok=True)
    if completed.returncode != 0:
        raise RecoveryError(f"model_recovery_exit_{completed.returncode}:{redact(completed.stderr or completed.stdout, 600)}")
    config_valid = command_ok(["openclaw", "config", "validate"], 60)
    gateway_healthy = command_ok(["openclaw", "gateway", "status"], 30)
    if not config_valid or not gateway_healthy:
        raise RecoveryError("post_recovery_validation_failed")
    receipt = safe_receipt(RUNTIME_DIR / "pi-openclaw-recovery-receipt.json")
    return {
        "result": "verified",
        "handler": "pi_supabase_auth_model_recovery",
        "installer_sha256": CANONICAL_INSTALLER_SHA256,
        "config_valid": config_valid,
        "gateway_healthy": gateway_healthy,
        "receipt": receipt,
        "provider_secret_returned": False,
        "secret_values_included": False,
    }


def handle_local_fallback(task: dict[str, Any]) -> dict[str, Any]:
    payload = task.get("payload") if isinstance(task.get("payload"), dict) else {}
    url = payload.get("recovery_script")
    digest = payload.get("script_sha256")
    if url != PINNED_OLLAMA_REPAIR_URL or digest != PINNED_OLLAMA_REPAIR_SHA256:
        raise RecoveryError("pinned_ollama_repair_contract_mismatch")
    script = download_verified(str(url), str(digest), PINNED_OLLAMA_REPAIR_URL)
    try:
        completed = run_command(["/usr/bin/env", "bash", str(script)], timeout=1800)
    finally:
        script.unlink(missing_ok=True)
    if completed.returncode != 0:
        raise RecoveryError(f"ollama_repair_exit_{completed.returncode}:{redact(completed.stderr or completed.stdout, 600)}")
    config_valid = command_ok(["openclaw", "config", "validate"], 60)
    gateway_healthy = command_ok(["openclaw", "gateway", "status"], 30)
    ollama_healthy = command_ok(["curl", "-fsS", "--max-time", "5", "http://127.0.0.1:11434/api/version"], 10)
    if not (config_valid and gateway_healthy and ollama_healthy):
        raise RecoveryError("post_ollama_repair_validation_failed")
    receipt = safe_receipt(RUNTIME_DIR / "telegram-model-recovery-receipt.json")
    return {
        "result": "verified",
        "handler": "telegram_model_failover_repair",
        "script_sha256": PINNED_OLLAMA_REPAIR_SHA256,
        "config_valid": config_valid,
        "gateway_healthy": gateway_healthy,
        "ollama_healthy": ollama_healthy,
        "receipt": receipt,
        "provider_secret_returned": False,
        "secret_values_included": False,
    }


def unit_exists(unit: str) -> bool:
    completed = run_command(["systemctl", "--user", "list-unit-files", unit, "--no-legend"], 15)
    return completed.returncode == 0 and unit in completed.stdout


def handle_liveness(_: dict[str, Any]) -> dict[str, Any]:
    known_timers = ["openclaw-pi-session-refresh.timer", "openclaw-recovery-queue.timer"]
    enabled: dict[str, bool] = {}
    for timer in known_timers:
        if unit_exists(timer):
            run_command(["systemctl", "--user", "enable", "--now", timer], 30)
            enabled[timer] = command_ok(["systemctl", "--user", "is-enabled", timer], 15)
        else:
            enabled[timer] = False
    gateway_healthy = command_ok(["openclaw", "gateway", "status"], 30)
    if not gateway_healthy or not enabled.get("openclaw-recovery-queue.timer", False):
        raise RecoveryError("recovery_worker_liveness_not_verified")
    return {
        "result": "verified",
        "handler": "worker_liveness_guardian",
        "gateway_healthy": gateway_healthy,
        "known_timers": enabled,
        "second_telegram_poller_created": False,
        "provider_secret_returned": False,
        "secret_values_included": False,
    }


def dispatch(task: dict[str, Any]) -> dict[str, Any]:
    task_type = task.get("task_type")
    if task_type not in ALLOWED_TASK_TYPES:
        raise RecoveryError("task_type_not_allowlisted")
    if task_type == "pi_supabase_auth_model_recovery":
        return handle_model_recovery(task)
    if task_type == "telegram_model_failover_repair":
        return handle_local_fallback(task)
    if task_type == "worker_liveness_guardian":
        return handle_liveness(task)
    raise RecoveryError("unsupported_allowlisted_task")


def store_receipt(payload: dict[str, Any]) -> None:
    safe = json.dumps(payload, indent=2, sort_keys=True)
    if SECRET_PATTERN.search(safe):
        raise RecoveryError("receipt_secret_pattern_rejected")
    atomic_write(RECEIPT_FILE, safe + "\n")


def main() -> int:
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    RUNTIME_DIR.chmod(0o700)
    with LOCK_FILE.open("a+", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({"result": "already_running", "secret_values_included": False}))
            return 0

        task: dict[str, Any] | None = None
        try:
            pulled = queue_request({"action": "pull_recovery", "lease_minutes": 45})
            candidate = pulled.get("task")
            if candidate is None:
                store_receipt({
                    "result": "idle",
                    "checked_at": int(time.time()),
                    "secret_values_included": False,
                })
                print(json.dumps({"result": "idle", "secret_values_included": False}))
                return 0
            if not isinstance(candidate, dict):
                raise RecoveryError("invalid_task_payload")
            task = candidate
            task_id = task.get("id")
            if not isinstance(task_id, str):
                raise RecoveryError("task_id_missing")
            evidence = dispatch(task)
            completed = queue_request({"action": "complete", "task_id": task_id, "evidence": evidence})
            receipt = {
                "result": "completed",
                "task_key": task.get("task_key"),
                "task_type": task.get("task_type"),
                "queue_status": completed.get("task", {}).get("status") if isinstance(completed.get("task"), dict) else None,
                "evidence": evidence,
                "completed_at": int(time.time()),
                "secret_values_included": False,
            }
            store_receipt(receipt)
            print(json.dumps(receipt, separators=(",", ":"), sort_keys=True))
            return 0
        except RecoveryError as error:
            message = redact(str(error), 800)
            if isinstance(task, dict) and isinstance(task.get("id"), str):
                try:
                    queue_request({"action": "fail", "task_id": task["id"], "error": message})
                except RecoveryError:
                    pass
            receipt = {
                "result": "blocked",
                "task_key": task.get("task_key") if isinstance(task, dict) else None,
                "task_type": task.get("task_type") if isinstance(task, dict) else None,
                "error": message,
                "checked_at": int(time.time()),
                "secret_values_included": False,
            }
            store_receipt(receipt)
            print(json.dumps(receipt, separators=(",", ":"), sort_keys=True), file=sys.stderr)
            return 40


if __name__ == "__main__":
    raise SystemExit(main())
