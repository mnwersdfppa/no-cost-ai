#!/usr/bin/env python3
"""Static safety checks for the OpenClaw compatibility guardian source."""

from __future__ import annotations

import json
import pathlib
import re

SOURCE = pathlib.Path(__file__).with_name("guardian.py")
text = SOURCE.read_text(encoding="utf-8")
runtime_text = text.split("\ndef self_test()", 1)[0]

checks = {
    "supported_platforms": all(value in runtime_text for value in ("linux/amd64", "linux/arm64")),
    "docker_socket_is_observation_only": (
        'pathlib.Path("/var/run/docker.sock").exists()' in runtime_text
        and "import docker" not in runtime_text
        and "from docker" not in runtime_text
        and "docker.from_env" not in runtime_text
        and "DockerClient" not in runtime_text
    ),
    "no_subprocess_execution": (
        re.search(
            r"^\s*(?:import\s+subprocess|from\s+subprocess\s+import)",
            runtime_text,
            re.MULTILINE,
        )
        is None
        and "subprocess.run(" not in runtime_text
        and "subprocess.Popen(" not in runtime_text
    ),
    "no_eval": "eval(" not in runtime_text,
    "no_exec": "exec(" not in runtime_text,
    "no_telegram_polling": "getUpdates" not in runtime_text,
    "secret_redaction": "dckr_(?:pat|oat)_" in runtime_text,
    "paid_fallback_off": '"paid_api_fallback": False' in runtime_text,
    "non_privileged_runtime": '"privileged": False' in runtime_text,
    "no_provider_secret_return": '"provider_secret_returned": False' in runtime_text,
}

print(json.dumps(checks, sort_keys=True))
raise SystemExit(0 if all(checks.values()) else 1)
