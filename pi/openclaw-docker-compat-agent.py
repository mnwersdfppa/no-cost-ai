#!/usr/bin/env python3
"""Deterministic Docker/native compatibility agent for Raspberry Pi OpenClaw.

The agent submits a non-secret host fingerprint to the authenticated Supabase
bootstrap, accepts only fixed typed steps, and never executes commands supplied
by queue payloads or arbitrary remote text.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from typing import Any

SUPABASE_URL_DEFAULT = "https://dpllasnpfskyyyzebyal.supabase.co"
BOOTSTRAP_PATH = "/functions/v1/pi-container-bootstrap"
IMAGE_TAG = "docker.io/odifool/openclaw-compat:2026.08.20"
IMAGE_DIGEST = "sha256:6c6df789c26cb0400171818fb0903d27ff799f9642d6e8c2eaf2b1c8e2e2894b"
IMAGE_BY_DIGEST = f"docker.io/odifool/openclaw-compat@{IMAGE_DIGEST}"
ROOT = pathlib.Path(os.environ.get("OPENCLAW_ROOT", pathlib.Path.home() / ".openclaw"))
ENV_FILE = pathlib.Path(
    os.environ.get("PI_WORK_QUEUE_ENV", ROOT / "secrets" / "pi-work-queue.env")
)
RUNTIME_DIR = pathlib.Path(
    os.environ.get("OPENCLAW_RUNTIME_DIR", ROOT / "runtime")
)
RECEIPT_FILE = RUNTIME_DIR / "docker-compatibility-receipt.json"
PLAN_FILE = RUNTIME_DIR / "docker-compatibility-plan.json"
LOCK_FILE = RUNTIME_DIR / "docker-compatibility-agent.lock"
MAX_BOOTSTRAP_BYTES = 256 * 1024
MAX_INSTALLER_BYTES = 1024 * 1024
TIMEOUT = 45
SECRET_PATTERN = re.compile(
    r"(sk-proj-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|"
    r"ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
    r"dckr_(?:pat|oat)_[A-Za-z0-9_-]{8,}|"
    r"tskey-[A-Za-z0-9_-]+|Bearer\s+[A-Za-z0-9._~-]{16,}|"
    r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})",
    re.IGNORECASE,
)
ALLOWED_DOCKER_FLAGS = {
    "--rm",
    "--pull=never",
    "--read-only",
    "--network=none",
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--pids-limit=64",
    "--memory=128m",
    "--cpus=0.5",
    "--platform=linux/amd64",
    "--platform=linux/arm64",
}
ALLOWED_STEP_TYPES = {
    "docker_pull",
    "docker_preflight",
    "download_verified_installer",
    "execute_verified_installer",
    "local_buildkit_preflight",
    "preserve_request_in_supabase_queue",
}


class CompatError(RuntimeError):
    pass


def redact(value: object, limit: int = 600) -> str:
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


def save_session(
    values: dict[str, str],
    access_token: str | None,
    refresh_token: str | None,
) -> None:
    if access_token:
        values["PI_ACCESS_TOKEN"] = access_token
    if refresh_token:
        values["PI_REFRESH_TOKEN"] = refresh_token
    atomic_write(
        ENV_FILE,
        "\n".join(f"{key}={values[key]}" for key in sorted(values)) + "\n",
        0o600,
    )


def normalize_arch(value: str) -> str:
    name = value.strip().lower()
    if name in {"aarch64", "arm64", "arm64v8", "armv8l"}:
        return "arm64"
    if name in {"x86_64", "amd64", "x64"}:
        return "amd64"
    if name in {"armv7l", "armhf", "arm/v7"}:
        return "arm/v7"
    return name


def run(
    command: list[str],
    timeout: int,
    *,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    if not command or any("\x00" in item for item in command):
        raise CompatError("INVALID_FIXED_COMMAND")
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
        raise CompatError(
            f"FIXED_COMMAND_FAILED:{pathlib.Path(command[0]).name}:"
            f"{completed.returncode}:{redact(completed.stderr)}"
        )
    return completed


def docker_prefix() -> list[str] | None:
    docker = shutil.which("docker")
    if docker:
        direct = run([docker, "info", "--format", "{{.ServerVersion}}"], 15, check=False)
        if direct.returncode == 0:
            return [docker]
    sudo = shutil.which("sudo")
    if docker and sudo:
        delegated = run(
            [sudo, "-n", docker, "info", "--format", "{{.ServerVersion}}"],
            15,
            check=False,
        )
        if delegated.returncode == 0:
            return [sudo, "-n", docker]
    return None


def memory_mb() -> int:
    try:
        for line in pathlib.Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if line.startswith("MemTotal:"):
                return max(1, int(line.split()[1]) // 1024)
    except (OSError, ValueError, IndexError):
        pass
    return 0


def disk_free_mb(path: pathlib.Path) -> int:
    try:
        return max(0, shutil.disk_usage(path.expanduser()).free // (1024 * 1024))
    except OSError:
        return 0


def docker_capabilities(prefix: list[str] | None, arch: str) -> dict[str, object]:
    if prefix is None:
        return {
            "docker_present": False,
            "buildx_present": False,
            "registry_pull_available": False,
            "docker_engine_version": None,
        }

    version = run(prefix + ["version", "--format", "{{.Server.Version}}"], 15, check=False)
    buildx = run(prefix + ["buildx", "version"], 15, check=False)
    manifest = run(
        prefix + ["manifest", "inspect", IMAGE_BY_DIGEST],
        35,
        check=False,
    )
    return {
        "docker_present": version.returncode == 0,
        "buildx_present": buildx.returncode == 0,
        "registry_pull_available": manifest.returncode == 0 and arch in {"amd64", "arm64"},
        "docker_engine_version": version.stdout.strip()[:80] if version.returncode == 0 else None,
    }


def request_json(
    url: str,
    body: dict[str, Any],
    *,
    access_token: str = "",
) -> dict[str, Any]:
    headers = {
        "content-type": "application/json",
        "user-agent": "openclaw-docker-compat-agent/1",
    }
    if access_token:
        headers["authorization"] = f"Bearer {access_token}"
    request = urllib.request.Request(
        url,
        data=json.dumps(body, separators=(",", ":")).encode(),
        method="POST",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            payload = response.read(MAX_BOOTSTRAP_BYTES + 1)
    except urllib.error.HTTPError as error:
        detail = error.read(4096)
        raise CompatError(f"BOOTSTRAP_HTTP_{error.code}:{redact(detail)}") from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise CompatError(f"BOOTSTRAP_UNREACHABLE:{type(error).__name__}") from error
    if len(payload) > MAX_BOOTSTRAP_BYTES:
        raise CompatError("BOOTSTRAP_RESPONSE_TOO_LARGE")
    try:
        parsed = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CompatError("BOOTSTRAP_INVALID_JSON") from error
    if not isinstance(parsed, dict):
        raise CompatError("BOOTSTRAP_INVALID_OBJECT")
    return parsed


def host_fingerprint(prefix: list[str] | None) -> dict[str, object]:
    arch_raw = platform.machine() or "unknown"
    arch = normalize_arch(arch_raw)
    capabilities = docker_capabilities(prefix, arch)
    return {
        "node_name": platform.node()[:120] or "raspberry-pi5",
        "host_os": "linux" if sys.platform.startswith("linux") else sys.platform,
        "host_arch": arch_raw,
        "host_bits": struct.calcsize("P") * 8,
        "memory_mb": memory_mb(),
        "runtime_disk_free_mb": disk_free_mb(ROOT.parent),
        **capabilities,
    }


def get_plan(
    values: dict[str, str],
    prefix: list[str] | None,
) -> dict[str, Any]:
    base = (
        os.environ.get("SUPABASE_URL")
        or values.get("SUPABASE_URL")
        or SUPABASE_URL_DEFAULT
    ).rstrip("/")
    refresh = os.environ.get("PI_REFRESH_TOKEN") or values.get("PI_REFRESH_TOKEN", "")
    access = os.environ.get("PI_ACCESS_TOKEN") or values.get("PI_ACCESS_TOKEN", "")
    if not base.startswith("https://"):
        raise CompatError("HTTPS_SUPABASE_URL_REQUIRED")
    if len(refresh) < 8 and len(access) < 20:
        raise CompatError("PI_SESSION_REQUIRED")

    body: dict[str, Any] = {
        "execution_key": f"docker-compat-{int(time.time())}-{uuid.uuid4().hex[:12]}",
        "correlation_id": f"docker-compat-{uuid.uuid4().hex}",
        **host_fingerprint(prefix),
    }
    if len(refresh) >= 8:
        body["refresh_token"] = refresh
    result = request_json(
        f"{base}{BOOTSTRAP_PATH}",
        body,
        access_token=access if len(access) >= 20 else "",
    )
    if result.get("ok") is not True:
        raise CompatError(f"BOOTSTRAP_REJECTED:{redact(result.get('error'))}")
    if result.get("provider_secret_returned") is not False:
        raise CompatError("PROVIDER_SECRET_BOUNDARY_UNCONFIRMED")
    if result.get("docker_registry_secret_returned") is not False:
        raise CompatError("DOCKER_SECRET_BOUNDARY_UNCONFIRMED")
    if result.get("version") != 3:
        raise CompatError("BOOTSTRAP_VERSION_MISMATCH")
    session = result.get("session")
    if isinstance(session, dict):
        rotated_access = session.get("access_token")
        rotated_refresh = session.get("refresh_token")
        save_session(
            values,
            rotated_access if isinstance(rotated_access, str) else None,
            rotated_refresh if isinstance(rotated_refresh, str) else None,
        )
    atomic_write(PLAN_FILE, json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def validate_docker_args(args: list[str], prefix: list[str]) -> list[str]:
    if not args:
        raise CompatError("EMPTY_DOCKER_ARGS")
    operation = args[0]
    if operation == "pull":
        if len(args) != 3:
            raise CompatError("INVALID_DOCKER_PULL_CONTRACT")
        if args[1] not in {"--platform=linux/amd64", "--platform=linux/arm64"}:
            raise CompatError("INVALID_DOCKER_PULL_PLATFORM")
        if args[2] != IMAGE_BY_DIGEST:
            raise CompatError("UNPINNED_DOCKER_IMAGE")
        return prefix + args
    if operation == "run":
        if IMAGE_BY_DIGEST not in args:
            raise CompatError("UNPINNED_DOCKER_IMAGE")
        image_index = args.index(IMAGE_BY_DIGEST)
        flags = args[1:image_index]
        if any(flag not in ALLOWED_DOCKER_FLAGS for flag in flags):
            raise CompatError("UNSAFE_DOCKER_FLAG")
        if args[image_index + 1 :] != ["status"]:
            raise CompatError("UNSAFE_CONTAINER_COMMAND")
        return prefix + args
    raise CompatError("UNSUPPORTED_DOCKER_OPERATION")


def download_verified(url: str, expected_sha: str, maximum_bytes: int) -> pathlib.Path:
    if not url.startswith("https://"):
        raise CompatError("HTTPS_INSTALLER_REQUIRED")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha):
        raise CompatError("INVALID_INSTALLER_SHA256")
    maximum = max(1, min(maximum_bytes, MAX_INSTALLER_BYTES))
    request = urllib.request.Request(
        url,
        headers={"user-agent": "openclaw-docker-compat-agent/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            data = response.read(maximum + 1)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
        raise CompatError("VERIFIED_INSTALLER_DOWNLOAD_FAILED") from error
    if len(data) > maximum:
        raise CompatError("VERIFIED_INSTALLER_TOO_LARGE")
    if hashlib.sha256(data).hexdigest() != expected_sha:
        raise CompatError("VERIFIED_INSTALLER_SHA_MISMATCH")
    if not data.startswith(b"#!/usr/bin/env bash"):
        raise CompatError("VERIFIED_INSTALLER_SHEBANG_INVALID")
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        prefix=".openclaw-docker-native-",
        suffix=".sh",
        dir=RUNTIME_DIR,
    )
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o700)
    return pathlib.Path(temporary)


def execute_plan(
    plan: dict[str, Any],
    prefix: list[str] | None,
    *,
    apply_native: bool,
) -> dict[str, Any]:
    execution = plan.get("execution_plan")
    if not isinstance(execution, dict):
        raise CompatError("EXECUTION_PLAN_MISSING")
    route = execution.get("route")
    steps = execution.get("steps")
    if not isinstance(route, str) or not isinstance(steps, list):
        raise CompatError("EXECUTION_PLAN_INVALID")

    outcomes: list[dict[str, object]] = []
    downloaded: pathlib.Path | None = None
    docker_degraded = False

    try:
        for step in steps:
            if not isinstance(step, dict):
                raise CompatError("INVALID_STEP")
            step_type = step.get("type")
            if step_type not in ALLOWED_STEP_TYPES:
                raise CompatError("STEP_TYPE_NOT_ALLOWED")

            if step_type in {"docker_pull", "docker_preflight"}:
                if prefix is None:
                    docker_degraded = True
                    outcomes.append({"type": step_type, "result": "docker_unavailable"})
                    continue
                args = step.get("args")
                if step.get("executable") != "docker" or step.get("shell") is not False:
                    raise CompatError("DOCKER_STEP_CONTRACT_INVALID")
                if not isinstance(args, list) or not all(isinstance(item, str) for item in args):
                    raise CompatError("DOCKER_ARGS_INVALID")
                command = validate_docker_args(list(args), prefix)
                completed = run(command, 180, check=False)
                if completed.returncode != 0:
                    docker_degraded = True
                    outcomes.append(
                        {
                            "type": step_type,
                            "result": "degraded",
                            "returncode": completed.returncode,
                            "error": redact(completed.stderr),
                        }
                    )
                    continue
                if step_type == "docker_preflight":
                    try:
                        data = json.loads(completed.stdout)
                    except json.JSONDecodeError as error:
                        raise CompatError("CONTAINER_STATUS_INVALID_JSON") from error
                    if (
                        not isinstance(data, dict)
                        or data.get("ok") is not True
                        or data.get("secret_values_included") is not False
                        or data.get("docker_socket_required") is not False
                    ):
                        raise CompatError("CONTAINER_STATUS_CONTRACT_FAILED")
                outcomes.append({"type": step_type, "result": "pass"})

            elif step_type == "local_buildkit_preflight":
                if prefix is None:
                    outcomes.append({"type": step_type, "result": "docker_unavailable"})
                else:
                    checked = run(prefix + ["buildx", "version"], 20, check=False)
                    outcomes.append(
                        {
                            "type": step_type,
                            "result": "pass" if checked.returncode == 0 else "degraded",
                        }
                    )

            elif step_type == "download_verified_installer":
                if not apply_native:
                    outcomes.append({"type": step_type, "result": "deferred_preflight_mode"})
                    continue
                url = step.get("url")
                sha = step.get("sha256")
                maximum = step.get("maximum_bytes", MAX_INSTALLER_BYTES)
                if not isinstance(url, str) or not isinstance(sha, str):
                    raise CompatError("INSTALLER_CONTRACT_INVALID")
                downloaded = download_verified(url, sha, int(maximum))
                outcomes.append({"type": step_type, "result": "pass", "sha256": sha})

            elif step_type == "execute_verified_installer":
                if not apply_native:
                    outcomes.append({"type": step_type, "result": "deferred_preflight_mode"})
                    continue
                if downloaded is None or step.get("executable") != "bash":
                    raise CompatError("VERIFIED_INSTALLER_NOT_READY")
                args = step.get("args")
                if args != ["<verified_download_path>"] or step.get("shell") is not False:
                    raise CompatError("INSTALLER_EXECUTION_CONTRACT_INVALID")
                run(["bash", str(downloaded)], 1800)
                outcomes.append({"type": step_type, "result": "pass"})

            elif step_type == "preserve_request_in_supabase_queue":
                outcomes.append({"type": step_type, "result": "cloud_queue_selected"})

        return {
            "route": route,
            "outcomes": outcomes,
            "docker_degraded": docker_degraded,
            "native_applied": apply_native
            and any(row.get("type") == "execute_verified_installer" and row.get("result") == "pass" for row in outcomes),
        }
    finally:
        if downloaded is not None:
            downloaded.unlink(missing_ok=True)


def write_receipt(payload: dict[str, Any]) -> None:
    clean = {
        **payload,
        "image": IMAGE_TAG,
        "image_digest": IMAGE_DIGEST,
        "provider_secret_exported": False,
        "docker_registry_secret_exported": False,
        "docker_socket_mounted": False,
        "second_telegram_poller_created": False,
        "paid_api_fallback": False,
        "secret_values_included": False,
    }
    atomic_write(RECEIPT_FILE, json.dumps(clean, indent=2, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        nargs="?",
        choices=("preflight", "apply", "status"),
        default="preflight",
    )
    args = parser.parse_args()

    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    RUNTIME_DIR.chmod(0o700)
    with LOCK_FILE.open("a+", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            write_receipt({"result": "already_running", "mode": args.mode})
            return 0

        if args.mode == "status":
            if RECEIPT_FILE.exists():
                print(RECEIPT_FILE.read_text(encoding="utf-8"), end="")
                return 0
            print(json.dumps({"result": "not_run", "secret_values_included": False}))
            return 1

        values = read_env(ENV_FILE)
        prefix = docker_prefix()
        try:
            plan = get_plan(values, prefix)
            result = execute_plan(
                plan,
                prefix,
                apply_native=args.mode == "apply",
            )
            receipt = {
                "result": "completed",
                "mode": args.mode,
                "bootstrap_version": plan.get("version"),
                "strategy": plan.get("strategy", {}).get("selected_strategy")
                if isinstance(plan.get("strategy"), dict)
                else None,
                "normalized_arch": plan.get("runtime_fingerprint", {}).get("host_arch")
                if isinstance(plan.get("runtime_fingerprint"), dict)
                else None,
                **result,
            }
            write_receipt(receipt)
            print(json.dumps(receipt, separators=(",", ":"), sort_keys=True))
            return 0
        except Exception as error:
            receipt = {
                "result": "failed",
                "mode": args.mode,
                "error": redact(error),
            }
            write_receipt(receipt)
            print(json.dumps(receipt, separators=(",", ":"), sort_keys=True), file=sys.stderr)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
