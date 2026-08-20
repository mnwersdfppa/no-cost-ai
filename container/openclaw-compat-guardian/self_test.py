#!/usr/bin/env python3
"""Static safety checks for the OpenClaw compatibility guardian source."""

from __future__ import annotations

import json
import pathlib
import re

SOURCE = pathlib.Path(__file__).with_name("guardian.py")
text = SOURCE.read_text(encoding="utf-8")

checks = {
    "supported_platforms": all(value in text for value in ("linux/amd64", "linux/arm64")),
    "docker_socket_is_observation_only": (
        'pathlib.Path("/var/run/docker.sock").exists()' in text
        and "import docker" not in text
        and "from docker" not in text
        and "docker.from_env" not in text
        and "DockerClient" not in text
    ),
    "no_subprocess_execution": (
        re.search(r"^\s*(?:import\s+subprocess|from\s+subprocess\s+import)", text, re.MULTILINE)
        is None
        and "subprocess.run(" not in text
        and "subprocess.Popen(" not in text
    ),
    "no_eval": "eval(" not in text,
    "no_exec": "exec(" not in text,
    "no_telegram_polling": "getUpdates" not in text,
    "secret_redaction": "dckr_(?:pat|oat)_" in text,
    "paid_fallback_off": '"paid_api_fallback": False' in text,
    "non_privileged_runtime": '"privileged": False' in text,
    "no_provider_secret_return": '"provider_secret_returned": False' in text,
}

print(json.dumps(checks, sort_keys=True))
raise SystemExit(0 if all(checks.values()) else 1)
