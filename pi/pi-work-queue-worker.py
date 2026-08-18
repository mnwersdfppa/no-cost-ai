#!/usr/bin/env python3
"""Bounded Raspberry Pi/OpenClaw work-queue worker.

Secrets are read from environment only. The worker never executes shell commands
from queue payloads; each task type maps to a hard-coded read-only handler.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
PI_ACCESS_TOKEN = os.environ.get("PI_ACCESS_TOKEN", "")
MAX_OUTPUT = 6000

SECRET_PATTERNS = [
    re.compile(r"sk-proj-[A-Za-z0-9_-]+"),
    re.compile(r"sk-[A-Za-z0-9_-]{20,}"),
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"Bearer\s+[A-Za-z0-9._-]+", re.I),
    re.compile(r"(token|password|secret|api[_-]?key)\s*[:=]\s*\S+", re.I),
]


def redact(value: str) -> str:
    result = value
    for pattern in SECRET_PATTERNS:
        result = pattern.sub("[REDACTED]", result)
    return result[:MAX_OUTPUT]


def api(action: str, **fields: Any) -> dict[str, Any]:
    if not SUPABASE_URL or not PI_ACCESS_TOKEN:
        raise RuntimeError("SUPABASE_URL and PI_ACCESS_TOKEN are required")
    body = json.dumps({"action": action, **fields}).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/functions/v1/pi-work-queue",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {PI_ACCESS_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"queue HTTP {exc.code}: {redact(detail)}") from exc


@dataclass
class CommandResult:
    command: list[str]
    returncode: int
    stdout: str
    stderr: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "command": self.command,
            "returncode": self.returncode,
            "stdout": redact(self.stdout),
            "stderr": redact(self.stderr),
        }


def run(command: list[str], timeout: int = 30) -> CommandResult:
    try:
        proc = subprocess.run(
            command,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
            env={**os.environ, "NO_COLOR": "1"},
        )
        return CommandResult(command, proc.returncode, proc.stdout, proc.stderr)
    except FileNotFoundError as exc:
        return CommandResult(command, 127, "", str(exc))
    except subprocess.TimeoutExpired as exc:
        return CommandResult(command, 124, exc.stdout or "", exc.stderr or "timeout")


def all_ok(results: list[CommandResult], allow: set[int] | None = None) -> bool:
    allowed = allow or {0}
    return all(result.returncode in allowed for result in results)


def handle_android_official_node_readiness(_: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    results = [
        run(["openclaw", "gateway", "status"]),
        run(["openclaw", "devices", "list", "--json"]),
        run(["openclaw", "nodes", "status"]),
    ]
    return all_ok(results), {"handler": "android_official_node_readiness", "results": [r.as_dict() for r in results]}


def handle_android_adb_readonly_mcp(_: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    results = [
        run(["adb", "devices"]),
        run(["openclaw", "mcp", "doctor", "android-safe", "--probe"], timeout=60),
    ]
    return all_ok(results), {"handler": "android_adb_readonly_mcp", "results": [r.as_dict() for r in results]}


def handle_telegram_health(_: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    results = [
        run(["openclaw", "status"]),
        run(["openclaw", "gateway", "status"]),
    ]
    return all_ok(results), {"handler": "telegram_health", "results": [r.as_dict() for r in results], "roundtrip_sent": False}


def handle_zero_cost_router_health(_: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    results = [
        run(["curl", "-fsS", "--max-time", "3", "http://127.0.0.1:11434/api/version"]),
        run(["ollama", "list"]),
    ]
    ok = results[0].returncode == 0
    return ok, {"handler": "zero_cost_router_health", "results": [r.as_dict() for r in results], "paid_fallback": False}


def handle_codex_oauth_catalog(_: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    results = [
        run(["openclaw", "models", "auth", "status"]),
        run(["openclaw", "models", "list"]),
    ]
    combined = "\n".join(r.stdout + r.stderr for r in results).lower()
    available = "openai" in combined
    return all_ok(results) and available, {"handler": "codex_oauth_catalog", "openai_catalog_seen": available, "results": [r.as_dict() for r in results], "model_call_performed": False}


def handle_integration_secret_index(_: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    return True, {"handler": "integration_secret_index", "note": "Inventory is maintained server-side; secret values were not requested."}


def handle_automation_packet_prepare(_: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    checks = [
        run(["git", "ls-remote", "https://github.com/mnwersdfppa/no-cost-ai.git", "refs/heads/feat/openclaw-android-node-absorber"]),
        run(["git", "ls-remote", "https://github.com/mnwersdfppa/content-factory-n8n-1000.git", "HEAD"]),
    ]
    return all_ok(checks), {"handler": "automation_packet_prepare", "results": [r.as_dict() for r in checks]}


def handle_final_report(_: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    results = [run(["openclaw", "status"]), run(["openclaw", "mcp", "status", "--verbose"])]
    return True, {"handler": "final_report", "results": [r.as_dict() for r in results], "secret_redaction": True}


HANDLERS: dict[str, Callable[[dict[str, Any]], tuple[bool, dict[str, Any]]]] = {
    "android_official_node_readiness": handle_android_official_node_readiness,
    "android_adb_readonly_mcp": handle_android_adb_readonly_mcp,
    "telegram_health": handle_telegram_health,
    "zero_cost_router_health": handle_zero_cost_router_health,
    "codex_oauth_catalog": handle_codex_oauth_catalog,
    "integration_secret_index": handle_integration_secret_index,
    "automation_packet_prepare": handle_automation_packet_prepare,
    "final_report": handle_final_report,
}


def main() -> int:
    response = api("pull", lease_minutes=15)
    task = response.get("task")
    if not task:
        print("QUEUE_EMPTY")
        return 0

    task_id = str(task["id"])
    task_type = str(task["task_type"])
    payload = task.get("payload") if isinstance(task.get("payload"), dict) else {}
    handler = HANDLERS.get(task_type)
    if not handler:
        api("fail", task_id=task_id, error=f"unsupported task type: {task_type}")
        print(f"TASK_UNSUPPORTED={task_type}")
        return 2

    try:
        ok, evidence = handler(payload)
    except Exception as exc:  # bounded failure path
        api("fail", task_id=task_id, error=redact(str(exc)))
        print(f"TASK_EXCEPTION={task_type}")
        return 1

    if ok:
        api("complete", task_id=task_id, evidence=evidence)
        print(f"TASK_COMPLETED={task_type}")
        return 0

    api("fail", task_id=task_id, error=f"handler validation failed: {task_type}")
    print(f"TASK_REQUEUED_OR_FAILED={task_type}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
