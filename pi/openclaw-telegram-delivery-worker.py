#!/usr/bin/env python3
"""Deliver completed Supabase retry results through the existing OpenClaw Telegram channel.

This worker is outbound-only. It never calls Telegram getUpdates, never reads a bot
token, and never starts another Telegram poller. It claims only the dedicated
``telegram_result_delivery`` contract from Supabase and invokes the fixed
``openclaw message send`` command.
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

ROOT = pathlib.Path(os.environ.get("OPENCLAW_ROOT", pathlib.Path.home() / ".openclaw"))
SECRETS_DIR = ROOT / "secrets"
RUNTIME_DIR = pathlib.Path(os.environ.get("OPENCLAW_RUNTIME_DIR", ROOT / "runtime"))
SESSION_ENV = pathlib.Path(
    os.environ.get("PI_WORK_QUEUE_ENV", SECRETS_DIR / "pi-work-queue.env")
)
LOCK_FILE = RUNTIME_DIR / "openclaw-telegram-delivery-worker.lock"
RECEIPT_FILE = RUNTIME_DIR / "openclaw-telegram-delivery-worker-receipt.json"
QUEUE_PATH = "pi-result-delivery-queue"
EXPECTED_TASK_TYPE = "telegram_result_delivery"
MAX_TEXT_CHARS = 4000
TARGET_RE = re.compile(r"^(?:-?\d{5,}|@[A-Za-z0-9_]{5,32})$")
SECRET_PATTERN = re.compile(
    r"(sk-proj-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|"
    r"ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]+|"
    r"tskey-[A-Za-z0-9_-]+|Bearer\s+[A-Za-z0-9._~-]{16,}|"
    r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})",
    re.IGNORECASE,
)

BASE = ""
ACCESS_TOKEN = ""
REFRESH_TOKEN = ""
PUBLISHABLE_KEY = ""


class DeliveryError(RuntimeError):
    pass


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
    ACCESS_TOKEN = os.environ.get("PI_ACCESS_TOKEN", values.get("PI_ACCESS_TOKEN", ""))
    REFRESH_TOKEN = os.environ.get("PI_REFRESH_TOKEN", values.get("PI_REFRESH_TOKEN", ""))
    PUBLISHABLE_KEY = os.environ.get(
        "SUPABASE_PUBLISHABLE_KEY", values.get("SUPABASE_PUBLISHABLE_KEY", "")
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
        raise DeliveryError("INVALID_JSON_RESPONSE") from error
    if not isinstance(value, dict):
        raise DeliveryError("INVALID_OBJECT_RESPONSE")
    return value


def refresh_session() -> bool:
    reload_session()
    if not BASE.startswith("https://") or len(REFRESH_TOKEN) < 20:
        return False
    request = urllib.request.Request(
        f"{BASE}/functions/v1/pi-auth-refresh",
        data=json.dumps({"refresh_token": REFRESH_TOKEN}, separators=(",", ":")).encode(),
        method="POST",
        headers={
            "content-type": "application/json",
            "user-agent": "openclaw-telegram-delivery-worker/1",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = decode_json(response.read(64 * 1024))
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, DeliveryError):
        return False
    access = payload.get("access_token")
    refresh = payload.get("refresh_token")
    if payload.get("ok") is not True or not isinstance(access, str) or len(access) < 20:
        return False
    if not isinstance(refresh, str) or len(refresh) < 20:
        refresh = REFRESH_TOKEN
    save_session(access, refresh)
    return True


def queue_request(body: dict[str, Any], retry_auth: bool = True) -> dict[str, Any]:
    reload_session()
    if not BASE.startswith("https://"):
        raise DeliveryError("HTTPS_SUPABASE_URL_REQUIRED")
    if len(ACCESS_TOKEN) < 20:
        if retry_auth and refresh_session():
            return queue_request(body, retry_auth=False)
        raise DeliveryError("PI_SESSION_REQUIRED")
    headers = {
        "authorization": f"Bearer {ACCESS_TOKEN}",
        "content-type": "application/json",
        "user-agent": "openclaw-telegram-delivery-worker/1",
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
        raise DeliveryError(f"QUEUE_HTTP_{error.code}") from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise DeliveryError(f"QUEUE_UNREACHABLE:{type(error).__name__}") from error
    if payload.get("ok") is not True:
        raise DeliveryError(f"QUEUE_REJECTED:{redact(payload.get('error'))}")
    if payload.get("values_exposed") is not False:
        raise DeliveryError("QUEUE_SECRET_BOUNDARY_UNCONFIRMED")
    if payload.get("server_secret_returned") is not False:
        raise DeliveryError("QUEUE_SERVER_SECRET_BOUNDARY_UNCONFIRMED")
    return payload


def run(command: list[str], timeout: int, *, check: bool = True) -> subprocess.CompletedProcess[str]:
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
        raise DeliveryError(
            f"FIXED_COMMAND_FAILED:{pathlib.Path(command[0]).name}:{completed.returncode}:"
            f"{redact(completed.stderr, 180)}"
        )
    return completed


def valid_target(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    candidate = value.strip()
    return candidate if TARGET_RE.fullmatch(candidate) else None


def collect_targets(value: object) -> set[str]:
    result: set[str] = set()
    candidate = valid_target(value)
    if candidate:
        result.add(candidate)
        return result
    if isinstance(value, list):
        for item in value:
            result.update(collect_targets(item))
    elif isinstance(value, dict):
        for key, item in value.items():
            lowered = str(key).lower()
            if lowered in {
                "allowfrom",
                "chatid",
                "chat_id",
                "target",
                "userid",
                "user_id",
                "accounts",
                "default",
            } or isinstance(item, (dict, list)):
                result.update(collect_targets(item))
    return result


def config_targets() -> set[str]:
    candidates: set[str] = set()
    for path in (
        "channels.telegram.allowFrom",
        "channels.telegram.accounts",
        "channels.telegram",
    ):
        completed = run(
            ["openclaw", "config", "get", path, "--json"],
            timeout=30,
            check=False,
        )
        if completed.returncode != 0 or not completed.stdout.strip():
            continue
        try:
            candidates.update(collect_targets(json.loads(completed.stdout)))
        except json.JSONDecodeError:
            continue
    return candidates


def resolve_target(payload: dict[str, Any], session: dict[str, str]) -> tuple[str, str]:
    payload_target = valid_target(payload.get("target"))
    if payload_target:
        return payload_target, "queue_payload"

    environment_target = valid_target(
        os.environ.get("OPENCLAW_TELEGRAM_TARGET")
        or session.get("OPENCLAW_TELEGRAM_TARGET")
    )
    if environment_target:
        return environment_target, "pi_environment"

    targets = config_targets()
    if len(targets) == 1:
        return next(iter(targets)), "openclaw_config"
    if not targets:
        raise DeliveryError("TELEGRAM_TARGET_NOT_RESOLVED")
    raise DeliveryError("TELEGRAM_TARGET_AMBIGUOUS")


def deliver(task: dict[str, Any]) -> dict[str, Any]:
    if task.get("task_type") != EXPECTED_TASK_TYPE:
        raise DeliveryError("TASK_TYPE_NOT_ALLOWED")
    payload = task.get("payload")
    if not isinstance(payload, dict):
        raise DeliveryError("INVALID_DELIVERY_PAYLOAD")
    if payload.get("delivery_mode") != "openclaw_message_send":
        raise DeliveryError("DELIVERY_MODE_NOT_ALLOWED")
    text = payload.get("text")
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT_CHARS:
        raise DeliveryError("INVALID_DELIVERY_TEXT")

    session = reload_session()
    target, target_source = resolve_target(payload, session)
    run(
        [
            "openclaw",
            "message",
            "send",
            "--channel",
            "telegram",
            "--target",
            target,
            "--message",
            text,
        ],
        timeout=90,
    )
    return {
        "handler": "openclaw_message_send",
        "channel": "telegram",
        "delivered": True,
        "outbound_only": True,
        "target_source": target_source,
        "second_poller_created": False,
        "provider_secret_returned": False,
        "secret_values_included": False,
    }


def write_receipt(payload: dict[str, Any]) -> None:
    atomic_write(
        RECEIPT_FILE,
        json.dumps({**payload, "secret_values_included": False}, indent=2, sort_keys=True) + "\n",
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

        pulled = queue_request({"action": "pull", "lease_minutes": 10})
        task = pulled.get("task")
        if task is None:
            write_receipt({"result": "idle", "contract_version": pulled.get("contract_version", 1)})
            return 0
        if not isinstance(task, dict):
            raise DeliveryError("INVALID_TASK_CONTRACT")
        task_id = task.get("id")
        task_key = task.get("task_key")
        if not isinstance(task_id, str) or not isinstance(task_key, str):
            raise DeliveryError("TASK_IDENTITY_MISSING")

        try:
            evidence = deliver(task)
            completed = queue_request(
                {"action": "complete", "task_id": task_id, "evidence": evidence}
            )
            receipt = {
                "result": "completed",
                "task_key": task_key,
                "queue_status": (
                    completed.get("task", {}).get("status")
                    if isinstance(completed.get("task"), dict)
                    else None
                ),
                "handler": evidence["handler"],
                "outbound_only": True,
                "second_poller_created": False,
                "secret_values_included": False,
            }
            write_receipt(receipt)
            print(json.dumps(receipt, separators=(",", ":"), sort_keys=True))
            return 0
        except Exception as error:
            reason = redact(error)
            try:
                queue_request({"action": "fail", "task_id": task_id, "error": reason})
            except Exception:
                pass
            write_receipt(
                {
                    "result": "failed",
                    "task_key": task_key,
                    "error": reason,
                    "second_poller_created": False,
                    "secret_values_included": False,
                }
            )
            raise DeliveryError(reason) from error


def self_test() -> int:
    source = pathlib.Path(__file__).read_text(encoding="utf-8")
    forbidden = {
        "subprocess_shell_true": "shell=True" in source,
        "payload_eval": "eval(task" in source or "exec(task" in source,
        "telegram_long_poll": ("get" + "Updates") in source,
        "telegram_bot_secret": ("TELEGRAM_" + "BOT_TOKEN") in source,
        "unknown_process_kill": "kill -9" in source or "pkill" in source,
    }
    ok = not any(forbidden.values()) and EXPECTED_TASK_TYPE in source
    print(
        json.dumps(
            {
                "ok": ok,
                "queue_path": QUEUE_PATH,
                "task_type": EXPECTED_TASK_TYPE,
                "delivery_command": "openclaw message send",
                "forbidden": forbidden,
                "outbound_only": True,
                "second_poller_created": False,
                "secret_values_included": False,
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0 if ok else 40


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        return self_test()
    try:
        return run_once()
    except DeliveryError as error:
        print(f"BLOCKED={redact(error)}", file=sys.stderr)
        return 40


if __name__ == "__main__":
    raise SystemExit(main())
