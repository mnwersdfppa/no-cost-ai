#!/usr/bin/env python3
"""OpenClaw runtime compatibility guardian.

This one-shot sidecar detects OS, CPU architecture, bitness, memory, disk,
configuration drift, and scoped Pi-session readiness. It never receives a
provider credential, never opens the Docker socket, and never controls the
Telegram poller.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import platform
import re
import shutil
import stat
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any, Iterable

DEFAULT_ROOT = pathlib.Path(os.environ.get("OPENCLAW_ROOT", "/openclaw"))
DEFAULT_RUNTIME = pathlib.Path(os.environ.get("OPENCLAW_RUNTIME_DIR", "/runtime"))
RECEIPT_NAME = "openclaw-container-compat-receipt.json"
OLD_MODEL = "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free"
EXPECTED_PRIMARY = os.environ.get(
    "EXPECTED_PRIMARY_MODEL",
    "supabase-opencode/nemotron-3-ultra-free",
)
EXPECTED_GATEWAY = os.environ.get(
    "EXPECTED_GATEWAY_URL",
    "https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/"
    "pi-model-gateway-guardian/v1",
)
SECRET_PATTERN = re.compile(
    r"(sk-proj-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|"
    r"(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}|"
    r"xox[baprs]-[A-Za-z0-9-]+|"
    r"tskey-[A-Za-z0-9_-]+|dckr_(?:pat|oat)_[A-Za-z0-9_-]+|"
    r"Bearer\s+[A-Za-z0-9._~+/-]{16,}|"
    r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})",
    re.IGNORECASE,
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def redact(value: object, limit: int = 500) -> str:
    return SECRET_PATTERN.sub("[REDACTED]", str(value))[:limit]


def normalize_arch(value: str) -> str:
    name = value.strip().lower()
    mapping = {
        "x86_64": "amd64",
        "amd64": "amd64",
        "aarch64": "arm64",
        "arm64": "arm64",
        "armv8l": "arm64",
        "armv7l": "arm/v7",
        "armhf": "arm/v7",
    }
    return mapping.get(name, name or "unknown")


def parse_int(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def read_os_release(path: pathlib.Path) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            if "=" not in raw or raw.lstrip().startswith("#"):
                continue
            key, value = raw.split("=", 1)
            result[key.strip()] = value.strip().strip('"')
    except OSError:
        pass
    return result


def memory_mb(path: pathlib.Path) -> int | None:
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return None


def disk_free_mb(path: pathlib.Path) -> int | None:
    try:
        return shutil.disk_usage(path).free // (1024 * 1024)
    except OSError:
        return None


def read_env_names(path: pathlib.Path) -> tuple[set[str], bool]:
    names: set[str] = set()
    safe_permissions = False
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
        safe_permissions = mode & 0o077 == 0
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key = line.split("=", 1)[0].strip()
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                names.add(key)
    except OSError:
        pass
    return names, safe_permissions


def iter_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from iter_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from iter_strings(item)


def inspect_config(root: pathlib.Path) -> dict[str, Any]:
    candidates = [
        root / "openclaw.json",
        root / "config.json",
        root / "config" / "openclaw.json",
        root / "config" / "config.json",
    ]
    for path in candidates:
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            corpus = "\n".join(iter_strings(data))
            return {
                "path_detected": str(path.relative_to(root)),
                "format": "json",
                "parse_ok": True,
                "obsolete_model_present": OLD_MODEL in corpus,
                "expected_primary_present": EXPECTED_PRIMARY in corpus,
                "provider_secret_literal_present": bool(SECRET_PATTERN.search(corpus)),
            }
        except (OSError, json.JSONDecodeError) as error:
            return {
                "path_detected": str(path.relative_to(root)),
                "format": "json",
                "parse_ok": False,
                "error": redact(type(error).__name__),
                "obsolete_model_present": None,
                "expected_primary_present": None,
                "provider_secret_literal_present": None,
            }
    return {
        "path_detected": None,
        "format": None,
        "parse_ok": None,
        "obsolete_model_present": None,
        "expected_primary_present": None,
        "provider_secret_literal_present": None,
    }


def http_probe(url: str, timeout: float = 6.0) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        method="GET",
        headers={"user-agent": "openclaw-container-compat-guardian/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response.read(1)
            return {"reachable": True, "status": response.status}
    except urllib.error.HTTPError as error:
        error.read(256)
        return {
            "reachable": True,
            "status": error.code,
            "auth_boundary_observed": error.code in (401, 403),
        }
    except (urllib.error.URLError, TimeoutError, OSError):
        return {"reachable": False, "status": None}


def write_receipt(runtime: pathlib.Path, receipt: dict[str, Any]) -> bool:
    try:
        runtime.mkdir(parents=True, exist_ok=True)
        target = runtime / RECEIPT_NAME
        temporary = runtime / f".{RECEIPT_NAME}.tmp"
        temporary.write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary.chmod(0o600)
        temporary.replace(target)
        return True
    except OSError:
        return False


def doctor(root: pathlib.Path, runtime: pathlib.Path) -> tuple[dict[str, Any], int]:
    container_arch = normalize_arch(platform.machine())
    host_arch = normalize_arch(os.environ.get("HOST_ARCH", container_arch))
    host_bits = parse_int(os.environ.get("HOST_BITS")) or (64 if sys.maxsize > 2**32 else 32)
    host_kernel = os.environ.get("HOST_KERNEL", "unknown")
    host_os_id = os.environ.get("HOST_OS_ID", "unknown").lower()
    host_os_version = os.environ.get("HOST_OS_VERSION", "unknown")
    host_memory = parse_int(os.environ.get("HOST_MEMORY_MB"))
    if host_memory is None:
        host_memory = memory_mb(pathlib.Path("/host/proc/meminfo")) or memory_mb(pathlib.Path("/proc/meminfo"))
    host_disk = parse_int(os.environ.get("HOST_DISK_FREE_MB"))
    if host_disk is None:
        host_disk = disk_free_mb(runtime)

    env_path = root / "secrets" / "pi-work-queue.env"
    env_names, env_permissions_safe = read_env_names(env_path)
    config = inspect_config(root)

    platform_supported = (
        platform.system().lower() == "linux"
        and host_os_id not in {"windows", "darwin"}
        and host_arch in {"arm64", "amd64"}
        and host_bits == 64
    )
    native_platform = host_arch == container_arch
    memory_ok = host_memory is None or host_memory >= 512
    disk_ok = host_disk is None or host_disk >= 1024
    local_build_space_ok = host_disk is None or host_disk >= 3072
    session_ready = {"SUPABASE_URL", "PI_REFRESH_TOKEN"}.issubset(env_names)
    config_repair_required = bool(
        config.get("obsolete_model_present") is True
        or config.get("expected_primary_present") is False
    )

    blockers: list[str] = []
    warnings: list[str] = []
    if not platform_supported:
        blockers.append("unsupported_host_platform")
    if not native_platform:
        blockers.append("container_architecture_mismatch")
    if not memory_ok:
        blockers.append("insufficient_memory")
    if not disk_ok:
        blockers.append("insufficient_runtime_disk")
    if not local_build_space_ok:
        warnings.append("local_container_build_not_recommended")
    if not session_ready:
        warnings.append("pi_session_refresh_material_missing")
    if env_path.exists() and not env_permissions_safe:
        warnings.append("pi_session_env_permissions_too_open")
    if config_repair_required:
        warnings.append("openclaw_model_config_repair_required")
    if config.get("provider_secret_literal_present") is True:
        blockers.append("provider_secret_literal_in_openclaw_config")

    gateway = http_probe(EXPECTED_GATEWAY)
    ollama_url = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434/api/tags")
    ollama = http_probe(ollama_url, timeout=2.5)

    if blockers:
        result = "blocked"
        strategy = "native_verified_installer_only"
        exit_code = 30
    elif warnings:
        result = "repair_required"
        strategy = (
            "prebuilt_multiarch_container_then_native_recovery"
            if local_build_space_ok
            else "native_verified_installer_then_container_recheck"
        )
        exit_code = 20
    else:
        result = "pass"
        strategy = "prebuilt_multiarch_container_then_native_recovery"
        exit_code = 0

    receipt: dict[str, Any] = {
        "schema_version": 1,
        "checked_at": utc_now(),
        "result": result,
        "strategy": strategy,
        "host": {
            "os": "linux",
            "os_id": host_os_id,
            "os_version": host_os_version,
            "kernel": host_kernel,
            "arch": host_arch,
            "bits": host_bits,
            "memory_mb": host_memory,
            "runtime_disk_free_mb": host_disk,
        },
        "container": {
            "os": platform.system().lower(),
            "arch": container_arch,
            "native_platform": native_platform,
            "supported_platforms": ["linux/amd64", "linux/arm64"],
            "privileged": False,
            "docker_socket_mounted": pathlib.Path("/var/run/docker.sock").exists(),
            "root_filesystem_expected_read_only": True,
        },
        "resource_policy": {
            "minimum_memory_mb": 512,
            "minimum_runtime_disk_mb": 1024,
            "recommended_local_build_disk_mb": 3072,
            "memory_ok": memory_ok,
            "runtime_disk_ok": disk_ok,
            "local_build_space_ok": local_build_space_ok,
        },
        "openclaw": {
            "config": config,
            "session_env_present": env_path.is_file(),
            "session_required_names_present": session_ready,
            "session_env_permissions_safe": env_permissions_safe,
            "expected_primary_model": EXPECTED_PRIMARY,
            "obsolete_model": OLD_MODEL,
        },
        "network": {
            "guardian_gateway": gateway,
            "ollama": ollama,
        },
        "blockers": sorted(set(blockers)),
        "warnings": sorted(set(warnings)),
        "security": {
            "provider_secret_received": False,
            "provider_secret_returned": False,
            "docker_registry_secret_received": False,
            "docker_socket_required": False,
            "host_pid_namespace_required": False,
            "second_telegram_poller_created": False,
            "paid_api_fallback": False,
            "secret_values_included": False,
        },
    }
    receipt["receipt_written"] = write_receipt(runtime, receipt)
    return receipt, exit_code


def self_test() -> int:
    source = pathlib.Path(__file__).read_text(encoding="utf-8")
    checks = {
        "supported_platforms": all(value in source for value in ("linux/amd64", "linux/arm64")),
        "no_docker_socket_use": "docker.sock" in source and "DockerClient" not in source,
        "no_subprocess": "subprocess" not in source,
        "no_eval": ("ev" + "al(") not in source,
        "no_exec": ("ex" + "ec(") not in source,
        "no_telegram_polling": ("get" + "Updates") not in source,
        "secret_redaction": "dckr_(?:pat|oat)_" in source,
        "paid_fallback_off": '"paid_api_fallback": False' in source,
    }
    print(json.dumps(checks, sort_keys=True))
    return 0 if all(checks.values()) else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", nargs="?", default="doctor", choices=("doctor", "self-test"))
    parser.add_argument("--root", default=str(DEFAULT_ROOT))
    parser.add_argument("--runtime", default=str(DEFAULT_RUNTIME))
    args = parser.parse_args()

    if args.command == "self-test":
        return self_test()
    receipt, code = doctor(pathlib.Path(args.root), pathlib.Path(args.runtime))
    print(json.dumps(receipt, separators=(",", ":"), sort_keys=True))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
