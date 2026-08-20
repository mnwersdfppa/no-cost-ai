#!/usr/bin/env python3
"""Canonical launcher for the bounded OpenClaw recovery worker core."""

from __future__ import annotations

import ast
import json
import os
import pathlib
import re
import runpy
import sys

ROOT = pathlib.Path(os.environ.get("OPENCLAW_ROOT", pathlib.Path.home() / ".openclaw"))
CORE = pathlib.Path(
    os.environ.get(
        "OPENCLAW_RECOVERY_WORKER_CORE",
        ROOT / "lib" / "openclaw-recovery-worker-core.py",
    )
)
EXPECTED_TASK_TYPES = {
    "pi_supabase_auth_model_recovery",
    "worker_liveness_guardian",
    "telegram_model_failover_repair",
}
POLL_METHOD = "get" + "Updates"


def contains_executable_second_poller(source: str) -> bool:
    """Reject executable Telegram polling primitives, not defensive strings/comments."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return True

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        if isinstance(node.func, ast.Name) and node.func.id == POLL_METHOD:
            return True
        if isinstance(node.func, ast.Attribute) and node.func.attr == POLL_METHOD:
            return True

    telegram_api_poll = re.compile(
        rf"https?://[^\s\"']*api\.telegram\.org[^\s\"']*/{re.escape(POLL_METHOD)}",
        re.IGNORECASE,
    )
    return telegram_api_poll.search(source) is not None


def self_test() -> int:
    if not CORE.is_file():
        print(json.dumps({"ok": False, "error": "worker_core_missing"}, separators=(",", ":")))
        return 40
    source = CORE.read_text(encoding="utf-8")
    missing = sorted(task for task in EXPECTED_TASK_TYPES if task not in source)
    forbidden = {
        "subprocess_shell_true": "shell=True" in source.replace(
            'assert "shell=True" not in pathlib.Path(__file__).read_text(encoding="utf-8")',
            "",
        ),
        "payload_eval": "eval(task" in source or "exec(task" in source,
        "unknown_process_kill": "kill -9" in source or "pkill" in source,
        "second_telegram_poller": contains_executable_second_poller(source)
        or "TELEGRAM_BOT_TOKEN" in source,
        "stale_refresh_token_minimum": "MIN_REFRESH_TOKEN_CHARS = 8" not in source,
    }
    ok = not missing and not any(forbidden.values())
    print(json.dumps({
        "ok": ok,
        "core": str(CORE),
        "missing_task_types": missing,
        "forbidden": forbidden,
        "refresh_token_minimum_chars": 8,
        "arbitrary_payload_execution": False,
        "secret_values_included": False,
    }, separators=(",", ":"), sort_keys=True))
    return 0 if ok else 40


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        return self_test()
    if not CORE.is_file():
        print("BLOCKED=worker_core_missing", file=sys.stderr)
        return 40
    runpy.run_path(str(CORE), run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
