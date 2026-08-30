#!/usr/bin/env python3
"""Deterministic OpenClaw recovery worker for Raspberry Pi 5.

The worker accepts only three fixed recovery task types. Queue payloads can
carry context, but can never supply commands or executable paths.
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
BIN_DIR = ROOT / "bin"
SESSION_ENV = pathlib.Path(
    os.environ.get("PI_WORK_QUEUE_ENV", SECRETS_DIR / "pi-work-queue.env")
)
LOCK_FILE = RUNTIME_DIR / "openclaw-recovery-worker-current.lock"
RECEIPT_FILE = RUNTIME_DIR / "openclaw-recovery-worker-current-receipt.json"
LOCAL_FALLBACK = pathlib.Path(
    os.environ.get(
        "OPENCLAW_LOCAL_FALLBACK_SCRIPT",
        BIN_DIR / "openclaw-local-fallback-repair",
    )
)

RECOVERY_INSTALLER_URL = (
    "https://dpllasnpfskyyyzebyal.supabase.co/"
    "functions/v1/pi-recovery-installer-current-format-verified"
)
RECOVERY_INSTALLER_SHA256 = (
    "0754e14b097578edfc2659390456162f88053c70d9610578d686438faa389f54"
)
QUEUE_PATH = "pi-work-queue"
MIN_REFRESH_TOKEN_CHARS = 8
ALLOWED_TASKS = frozenset(
    {
        "pi_supabase_auth_model_recovery",
        "worker_liveness_guardian",
        "telegram_model_failover_repair",
    }
)
SECRET_PATTERN = re.compile(
    r"(sk-proj-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|"
    r"(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}|"
    r"xox[baprs]-[A-Za-z0-9-]+|"
    r"tskey-[A-Za-z0-9_-]+|"
    r"Bearer\s+[A-Za-z0-9._~+/-]{16,}|"
    r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})",
    re.IGNORECASE,
)

BASE = ""
ACCESS_TOKEN = ""
REFRESH_TOKEN = ""
PUBLISHABLE_KEY = ""


class RecoveryError(RuntimeError):
    """Bounded recovery failure."""


def redact(value: object, limit: int = 500) -> str:
    return SECRET_PATTERN.sub("[REDACTED]", str(value))[:limit]


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


def reload_session() -> dict[str, str]:
    global BASE, ACCESS_TOKEN, REFRESH_TOKEN, PUBLISHABLE_KEY
    values = read_env(SESSION_ENV)
    BASE = os.environ.get("SUPABASE_URL", values.get("SUPABASE_URL", "")).rstrip("/")
    ACCESS_TOKEN = os.environ.get(
        "PI_ACCESS_TOKEN", values.get("PI_ACCESS_TOKEN", "")
    )
    REFRESH_TOKEN = os.environ.get(
        "PI_REFRESH_TOKEN", values.get("PI_REFRESH_TOKEN", "")
    )
    PUBLISHABLE_KEY = os.environ.get(
        "SUPABASE_PUBLISHABLE_KEY",
        values.get("SUPABASE_PUBLISHABLE_KEY", ""),
    )
    return values


def save_session(access: str, refresh: str) -> None:
    values = read_env(SESSION_ENV)
    values["SUPABASE_URL"] = BASE
    values["PI_ACCESS_TOKEN"] = access
    values["PI_REFRESH_TOKEN"] = refresh
    if PUBLISHABLE_KEY:
        values["SUPABASE_PUBLISHABLE_KEY"] = PUBLISHABLE_KEY
    atomic_write(
        SESSION_ENV,
        "\n".join(f"{key}={values[key]}" for key in sorted(values)) + "\n",
    )
    reload_session()


def decode_json(data: bytes) -> dict[str, Any]:
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RecoveryError("INVALID_JSON_RESPONSE") from error
    if not isinstance(value, dict):
        raise RecoveryError("INVALID_OBJECT_RESPONSE")
    return value


def refresh_session() -> bool:
    reload_session()
    if (
        not BASE.startswith("https://")
        or len(REFRESH_TOKEN) < MIN_REFRESH_TOKEN_CHARS
        or len(REFRESH_TOKEN) > 4096
    ):
        return False

    request = urllib.request.Request(
        f"{BASE}/functions/v1/pi-auth-refresh",
        data=json.dumps(
            {"refresh_token": REFRESH_TOKEN},
            separators=(",", ":"),
        ).encode(),
        method="POST",
        headers={
            "content-type": "application/json",
            "user-agent": "openclaw-recovery-worker-current/1",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = decode_json(response.read(64 * 1024))
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
        RecoveryError,
    ):
        return False

    access = payload.get("access_token")
    refresh = payload.get("refresh_token")
    if (
        payload.get("ok") is not True
        or payload.get("role") != "pi-gateway-client"
        or not isinstance(access, str)
        or len(access) < 20
    ):
        return False
    if not isinstance(refresh, str) or len(refresh) < MIN_REFRESH_TOKEN_CHARS:
        refresh = REFRESH_TOKEN
    save_session(access, refresh)
    return True


def queue_request(
    body: dict[str, Any],
    *,
    retry_auth: bool = True,
) -> dict[str, Any]:
    reload_session()
    if not BASE.startswith("https://"):
        raise RecoveryError("HTTPS_SUPABASE_URL_REQUIRED")
    if len(ACCESS_TOKEN) < 20:
        if retry_auth and refresh_session():
            return queue_request(body, retry_auth=False)
        raise RecoveryError("PI_SESSION_REQUIRED")

    headers = {
        "authorization": f"Bearer {ACCESS_TOKEN}",
        "content-type": "application/json",
        "user-agent": "openclaw-recovery-worker-current/1",
    }
    if PUBLISHABLE_KEY:
        headers["apikey"] = PUBLISHABLE_KEY

    request = urllib.request.Request(
        f"{BASE}/functions/v1/{QUEUE_PATH}",
        data=json.dumps(body, separators=(",", ":")).encode(),
        method="POST",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = decode_json(response.read(128 * 1024))
    except urllib.error.HTTPError as error:
        error.read(4096)
        if error.code == 401 and retry_auth and refresh_session():
            return queue_request(body, retry_auth=False)
        raise RecoveryError(f"QUEUE_HTTP_{error.code}") from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise RecoveryError(
            f"QUEUE_UNREACHABLE:{type(error).__name__}"
        ) from error

    if payload.get("ok") is not True:
        raise RecoveryError(f"QUEUE_REJECTED:{redact(payload.get('error'))}")
    if payload.get("values_exposed") is not False:
        raise RecoveryError("QUEUE_SECRET_BOUNDARY_UNCONFIRMED")
    if payload.get("server_secret_returned") is not False:
        raise RecoveryError("QUEUE_SERVER_SECRET_BOUNDARY_UNCONFIRMED")
    return payload


def run_fixed(
    command: list[str],
    timeout: int,
    *,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
        env={**os.environ, "NO_COLOR": "1"},
    )
    if check and completed.returncode != 0:
        raise RecoveryError(
            f"FIXED_COMMAND_FAILED:{pathlib.Path(command[0]).name}:"
            f"{completed.returncode}"
        )
    return completed


def download_recovery_installer() -> pathlib.Path:
    request = urllib.request.Request(
        RECOVERY_INSTALLER_URL,
        headers={"user-agent": "openclaw-recovery-worker-current/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=40) as response:
            data = response.read(512 * 1024)
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
    ) as error:
        raise RecoveryError("VERIFIED_INSTALLER_DOWNLOAD_FAILED") from error

    digest = hashlib.sha256(data).hexdigest()
    if (
        digest != RECOVERY_INSTALLER_SHA256
        or not data.startswith(b"#!/usr/bin/env bash")
    ):
        raise RecoveryError("VERIFIED_INSTALLER_INTEGRITY_FAILED")

    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    RUNTIME_DIR.chmod(0o700)
    fd, temporary = tempfile.mkstemp(
        prefix=".pi-current-recovery-",
        suffix=".sh",
        dir=RUNTIME_DIR,
    )
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o700)
    return pathlib.Path(temporary)


def handle_model_auth_recovery() -> dict[str, Any]:
    installer = download_recovery_installer()
    try:
        run_fixed(["bash", str(installer)], timeout=900)
    finally:
        installer.unlink(missing_ok=True)
    reload_session()
    receipt = RUNTIME_DIR / "pi-openclaw-recovery-receipt.json"
    return {
        "handler": "current_format_model_auth_recovery",
        "installer_sha256": RECOVERY_INSTALLER_SHA256,
        "receipt_present": receipt.exists(),
        "minimum_refresh_token_chars": MIN_REFRESH_TOKEN_CHARS,
        "provider_secret_exported": False,
        "secret_values_included": False,
    }


def unit_exists(name: str) -> bool:
    result = run_fixed(
        ["systemctl", "--user", "list-unit-files", name, "--no-legend"],
        timeout=15,
        check=False,
    )
    return name in result.stdout


def handle_liveness() -> dict[str, Any]:
    timer_results: dict[str, str] = {}
    for timer in (
        "openclaw-pi-recovery-worker-current.timer",
        "openclaw-pi-session-refresh.timer",
        "openclaw-telegram-delivery-worker.timer",
    ):
        if unit_exists(timer):
            result = run_fixed(
                ["systemctl", "--user", "enable", "--now", timer],
                timeout=30,
                check=False,
            )
            timer_results[timer] = (
                "active" if result.returncode == 0 else "degraded"
            )
        else:
            timer_results[timer] = "not_installed"

    gateway = run_fixed(
        ["openclaw", "gateway", "status"],
        timeout=30,
        check=False,
    )
    restarted = False
    if gateway.returncode != 0:
        run_fixed(["openclaw", "gateway", "restart"], timeout=90)
        time.sleep(3)
        run_fixed(["openclaw", "gateway", "status"], timeout=30)
        restarted = True

    return {
        "handler": "known_service_liveness",
        "timers": timer_results,
        "gateway_healthy": True,
        "gateway_restarted": restarted,
        "unknown_processes_killed": False,
        "secret_values_included": False,
    }


def handle_local_fallback() -> dict[str, Any]:
    if not LOCAL_FALLBACK.is_file() or not os.access(LOCAL_FALLBACK, os.X_OK):
        raise RecoveryError("LOCAL_FALLBACK_HANDLER_MISSING")
    run_fixed([str(LOCAL_FALLBACK)], timeout=1200)
    receipt = RUNTIME_DIR / "telegram-local-fallback-receipt.json"
    return {
        "handler": "local_ollama_fallback",
        "model": "ollama/qwen2.5:3b",
        "receipt_present": receipt.exists(),
        "primary": "supabase-opencode/nemotron-3-ultra-free",
        "paid_fallback_enabled": False,
        "second_telegram_poller_created": False,
        "secret_values_included": False,
    }


def execute_task(task: dict[str, Any]) -> dict[str, Any]:
    task_type = task.get("task_type")
    if not isinstance(task_type, str) or task_type not in ALLOWED_TASKS:
        raise RecoveryError("TASK_TYPE_NOT_ALLOWED")
    payload = task.get("payload")
    if isinstance(payload, dict) and any(
        key in payload
        for key in ("command", "commands", "shell", "argv", "executable")
    ):
        raise RecoveryError("EXECUTABLE_PAYLOAD_FIELD_REJECTED")

    if task_type == "pi_supabase_auth_model_recovery":
        return handle_model_auth_recovery()
    if task_type == "worker_liveness_guardian":
        return handle_liveness()
    if task_type == "telegram_model_failover_repair":
        return handle_local_fallback()
    raise RecoveryError("NO_FIXED_HANDLER")


def write_receipt(payload: dict[str, Any]) -> None:
    clean = {**payload, "secret_values_included": False}
    atomic_write(
        RECEIPT_FILE,
        json.dumps(clean, indent=2, sort_keys=True) + "\n",
    )


def run_once() -> int:
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    RUNTIME_DIR.chmod(0o700)
    with LOCK_FILE.open("a+", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            write_receipt({"result": "already_running"})
            return 0

        pulled = queue_request(
            {"action": "pull_recovery", "lease_minutes": 20}
        )
        task = pulled.get("task")
        if task is None:
            write_receipt(
                {
                    "result": "idle",
                    "contract_version": pulled.get("contract_version", 2),
                }
            )
            return 0
        if not isinstance(task, dict):
            raise RecoveryError("INVALID_TASK_CONTRACT")

        task_id = task.get("id")
        task_key = task.get("task_key")
        task_type = task.get("task_type")
        if not all(
            isinstance(value, str)
            for value in (task_id, task_key, task_type)
        ):
            raise RecoveryError("TASK_IDENTITY_MISSING")

        try:
            evidence = execute_task(task)
            reload_session()
            completed = queue_request(
                {
                    "action": "complete",
                    "task_id": task_id,
                    "evidence": evidence,
                }
            )
            completed_task = completed.get("task")
            receipt = {
                "result": "completed",
                "task_key": task_key,
                "task_type": task_type,
                "queue_status": (
                    completed_task.get("status")
                    if isinstance(completed_task, dict)
                    else None
                ),
                "handler": evidence.get("handler"),
                "secret_values_included": False,
            }
            write_receipt(receipt)
            print(json.dumps(receipt, separators=(",", ":"), sort_keys=True))
            return 0
        except Exception as error:
            reason = redact(error)
            try:
                reload_session()
                queue_request(
                    {
                        "action": "fail",
                        "task_id": task_id,
                        "error": reason,
                    }
                )
            except Exception:
                pass
            write_receipt(
                {
                    "result": "failed",
                    "task_key": task_key,
                    "task_type": task_type,
                    "error": reason,
                }
            )
            raise


def self_test() -> int:
    source = pathlib.Path(__file__).read_text(encoding="utf-8")
    checks = {
        "allowed_task_count": len(ALLOWED_TASKS) == 3,
        "current_installer": (
            "pi-recovery-installer-current-format-verified" in source
        ),
        "refresh_minimum": MIN_REFRESH_TOKEN_CHARS == 8,
        "no_shell_true": "shell" + "=True" not in source.replace(" ", ""),
        "no_eval": ("ev" + "al(") not in source,
        "no_exec": ("ex" + "ec(") not in source,
        "single_telegram_poller": ("get" + "Updates") not in source,
        "paid_fallback_off": "paid_fallback_enabled\": True" not in source,
    }
    print(json.dumps(checks, sort_keys=True))
    return 0 if all(checks.values()) else 1


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        return self_test()
    try:
        return run_once()
    except Exception as error:
        clean = redact(error)
        write_receipt({"result": "failed_before_completion", "error": clean})
        print(f"ERROR={clean}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
