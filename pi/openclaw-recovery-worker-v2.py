#!/usr/bin/env python3
"""Canonical launcher for the bounded OpenClaw recovery worker core."""

from __future__ import annotations

import json
import os
import pathlib
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
        "second_telegram_poller": "getUpdates" in source or "TELEGRAM_BOT_TOKEN" in source,
    }
    ok = not missing and not any(forbidden.values())
    print(json.dumps({
        "ok": ok,
        "core": str(CORE),
        "missing_task_types": missing,
        "forbidden": forbidden,
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
