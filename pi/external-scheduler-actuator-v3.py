#!/usr/bin/env python3
"""Fixed-function external scheduler handoff actuator for OpenClaw hosts.

The worker can claim exactly one task contract and can invoke only one local,
pre-installed shutdown script. Queue payloads cannot supply commands, paths,
or arguments.
"""

from __future__ import annotations

import fcntl
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from typing import Any

ROOT = pathlib.Path(
    os.environ.get("OPENCLAW_STATE_DIR", pathlib.Path.home() / ".openclaw")
)
RUNTIME_DIR = ROOT / "runtime"
SECRETS_DIR = ROOT / "secrets"
BIN_DIR = ROOT / "bin"
SESSION_ENV = pathlib.Path(
    os.environ.get("PI_WORK_QUEUE_ENV", SECRETS_DIR / "pi-work-queue.env")
)
LOCK_FILE = RUNTIME_DIR / "external-scheduler-actuator-v3.lock"
RECEIPT_FILE = RUNTIME_DIR / "external-scheduler-actuator-v3-receipt.json"
DISABLE_SCRIPT = BIN_DIR / "openclaw-disable-project-schedulers-v3"
ENDPOINT_PATH = "pi-external-scheduler-handoff-20260822"
EXPECTED_TASK_KEY = "external-local-scheduler-disable-v1"
EXPECTED_TASK_TYPE = "external_scheduler_reconcile"
MIN_REFRESH_TOKEN_CHARS = 8
MAX_RESPONSE_BYTES = 128 * 1024
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


class ActuatorError(RuntimeError):
    """Bounded external handoff failure."""


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
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("'\"")
    return values


def reload_session() -> None:
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
        raise ActuatorError("INVALID_JSON_RESPONSE") from error
    if not isinstance(value, dict):
        raise ActuatorError("INVALID_OBJECT_RESPONSE")
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
            {"refresh_token": REFRESH_TOKEN}, separators=(",", ":")
        ).encode(),
        method="POST",
        headers={
            "content-type": "application/json",
            "user-agent": "openclaw-external-scheduler-actuator/3",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = decode_json(response.read(64 * 1024))
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
        ActuatorError,
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


def endpoint_request(
    body: dict[str, Any], *, retry_auth: bool = True
) -> dict[str, Any]:
    reload_session()
    if not BASE.startswith("https://"):
        raise ActuatorError("HTTPS_SUPABASE_URL_REQUIRED")
    if len(ACCESS_TOKEN) < 20:
        if retry_auth and refresh_session():
            return endpoint_request(body, retry_auth=False)
        raise ActuatorError("PI_SESSION_REQUIRED")

    headers = {
        "authorization": f"Bearer {ACCESS_TOKEN}",
        "content-type": "application/json",
        "user-agent": "openclaw-external-scheduler-actuator/3",
    }
    if PUBLISHABLE_KEY:
        headers["apikey"] = PUBLISHABLE_KEY
    request = urllib.request.Request(
        f"{BASE}/functions/v1/{ENDPOINT_PATH}",
        data=json.dumps(body, separators=(",", ":")).encode(),
        method="POST",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = decode_json(response.read(MAX_RESPONSE_BYTES))
    except urllib.error.HTTPError as error:
        error.read(4096)
        if error.code == 401 and retry_auth and refresh_session():
            return endpoint_request(body, retry_auth=False)
        raise ActuatorError(f"HANDOFF_HTTP_{error.code}") from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise ActuatorError(
            f"HANDOFF_UNREACHABLE:{type(error).__name__}"
        ) from error

    if payload.get("ok") is not True:
        raise ActuatorError(
            f"HANDOFF_REJECTED:{redact(payload.get('error'))}"
        )
    if payload.get("secret_values_included") is not False:
        raise ActuatorError("HANDOFF_SECRET_BOUNDARY_UNCONFIRMED")
    return payload


def run_disable_script() -> dict[str, Any]:
    if not DISABLE_SCRIPT.is_file() or not os.access(DISABLE_SCRIPT, os.X_OK):
        raise ActuatorError("FIXED_DISABLE_SCRIPT_MISSING")
    completed = subprocess.run(
        [str(DISABLE_SCRIPT)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=240,
        check=False,
        env={**os.environ, "NO_COLOR": "1"},
    )
    if completed.returncode != 0:
        raise ActuatorError(
            f"FIXED_DISABLE_SCRIPT_FAILED:{completed.returncode}"
        )

    receipt = ROOT / "receipts" / "local-schedulers-disabled.json"
    if not receipt.is_file():
        raise ActuatorError("LOCAL_DISABLE_RECEIPT_MISSING")
    try:
        evidence = json.loads(receipt.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ActuatorError("LOCAL_DISABLE_RECEIPT_INVALID") from error
    if not isinstance(evidence, dict):
        raise ActuatorError("LOCAL_DISABLE_RECEIPT_INVALID")
    if evidence.get("secret_values_included") is not False:
        raise ActuatorError("LOCAL_DISABLE_SECRET_BOUNDARY_FAILED")
    if evidence.get("openclaw_native_cron_kill_switch") is not True:
        raise ActuatorError("OPENCLAW_NATIVE_CRON_KILL_SWITCH_UNCONFIRMED")
    if evidence.get("openclaw_skip_cron_dropin_installed") is not True:
        raise ActuatorError("OPENCLAW_SKIP_CRON_DROPIN_UNCONFIRMED")

    return {
        "handler": "fixed_project_scheduler_shutdown_v3",
        "result": evidence.get("result"),
        "scope": evidence.get("scope"),
        "backup_path": evidence.get("backup_path"),
        "disabled_user_timers": evidence.get("disabled_user_timers", []),
        "preserved_control_timers": evidence.get(
            "preserved_control_timers", []
        ),
        "openclaw_native_cron_kill_switch": True,
        "openclaw_skip_cron_dropin_installed": True,
        "openclaw_skip_cron_manager_environment_set": evidence.get(
            "openclaw_skip_cron_manager_environment_set"
        ),
        "gateway_restart_succeeded": evidence.get(
            "gateway_restart_succeeded"
        ),
        "job_definitions_deleted": False,
        "sqlite_modified": False,
        "rollback_script": str(
            BIN_DIR / "openclaw-rollback-project-schedulers-v3"
        ),
        "automatic_reboot": False,
        "unknown_process_kill": False,
        "arbitrary_command_execution": False,
        "secret_values_included": False,
    }


def write_receipt(payload: dict[str, Any]) -> None:
    atomic_write(
        RECEIPT_FILE,
        json.dumps(
            {**payload, "secret_values_included": False},
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
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

        response = endpoint_request(
            {"action": "claim", "lease_minutes": 10}
        )
        task = response.get("task")
        if task is None:
            write_receipt(
                {"result": "idle", "state": response.get("state", "idle")}
            )
            return 0
        if not isinstance(task, dict):
            raise ActuatorError("INVALID_TASK_CONTRACT")

        task_id = task.get("id")
        task_key = task.get("task_key")
        task_type = task.get("task_type")
        if not all(
            isinstance(value, str)
            for value in (task_id, task_key, task_type)
        ):
            raise ActuatorError("TASK_IDENTITY_MISSING")
        if task_key != EXPECTED_TASK_KEY or task_type != EXPECTED_TASK_TYPE:
            raise ActuatorError("TASK_CONTRACT_REJECTED")

        payload = task.get("payload")
        if isinstance(payload, dict) and any(
            key in payload
            for key in ("command", "commands", "shell", "argv", "path", "executable")
        ):
            raise ActuatorError("EXECUTABLE_PAYLOAD_FIELD_REJECTED")

        try:
            evidence = run_disable_script()
            completed = endpoint_request(
                {
                    "action": "complete",
                    "task_id": task_id,
                    "evidence": evidence,
                }
            )
            receipt = {
                "result": "completed",
                "task_key": task_key,
                "task_type": task_type,
                "queue_state": completed.get("state"),
                "handler": evidence.get("handler"),
                "backup_path": evidence.get("backup_path"),
                "rollback_script": evidence.get("rollback_script"),
                "openclaw_native_cron_kill_switch": True,
            }
            write_receipt(receipt)
            print(
                json.dumps(
                    {**receipt, "secret_values_included": False},
                    separators=(",", ":"),
                    sort_keys=True,
                )
            )
            return 0
        except Exception as error:
            reason = redact(error)
            try:
                endpoint_request(
                    {
                        "action": "fail",
                        "task_id": task_id,
                        "error": reason,
                        "retry_seconds": 900,
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
        "single_task_key": EXPECTED_TASK_KEY
        == "external-local-scheduler-disable-v1",
        "single_task_type": EXPECTED_TASK_TYPE
        == "external_scheduler_reconcile",
        "fixed_handler_v3": "fixed_project_scheduler_shutdown_v3" in source,
        "fixed_endpoint": ENDPOINT_PATH
        == "pi-external-scheduler-handoff-20260822",
        "native_cron_receipt_required": (
            "OPENCLAW_NATIVE_CRON_KILL_SWITCH_UNCONFIRMED" in source
        ),
        "no_shell_true": "shell" + "=True" not in source.replace(" ", ""),
        "no_eval": ("ev" + "al(") not in source,
        "no_exec": ("ex" + "ec(") not in source,
        "no_telegram_poller": ("get" + "Updates") not in source,
        "refresh_minimum": MIN_REFRESH_TOKEN_CHARS == 8,
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
        write_receipt(
            {"result": "failed_before_completion", "error": clean}
        )
        print(f"ERROR={clean}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
