#!/usr/bin/env python3
"""Fetch and validate the canonical Supabase/Vercel client configuration.

The agent never prints access tokens, refresh tokens, publishable keys, or server
secrets. It fails closed and atomically replaces cached configuration only after
all policy invariants pass.
"""

from __future__ import annotations

import json
import os
import shlex
import stat
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

EXPECTED_PROJECT_REF = "dpllasnpfskyyyzebyal"
EXPECTED_URL = "https://dpllasnpfskyyyzebyal.supabase.co"
EXPECTED_VERCEL_TEAM = "team_sa2sEffAlVXK6b9lsweDm6QL"


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


SUPABASE_URL = env("SUPABASE_URL", EXPECTED_URL).rstrip("/")
ACCESS_TOKEN = env("PI_ACCESS_TOKEN")
REFRESH_TOKEN = env("PI_REFRESH_TOKEN")
RUNTIME_DIR = Path(env("OPENCLAW_RUNTIME_DIR", str(Path.home() / ".openclaw" / "runtime")))
CONFIG_PATH = Path(env("CANONICAL_CONFIG_PATH", str(RUNTIME_DIR / "canonical-client.json")))
CLIENT_ENV_PATH = Path(env("CANONICAL_CLIENT_ENV_PATH", str(RUNTIME_DIR / "supabase-client.env")))
SESSION_ENV_PATH = Path(env("SESSION_ENV_PATH", str(Path.home() / ".openclaw" / "secrets" / "pi-canonical-config.env")))


class BridgeError(RuntimeError):
    pass


def request_json(url: str, *, method: str = "GET", headers: dict[str, str] | None = None, body: dict[str, Any] | None = None, timeout: int = 30) -> tuple[int, dict[str, Any]]:
    payload = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    request = urllib.request.Request(
        url,
        data=payload,
        method=method,
        headers={"Accept": "application/json", "User-Agent": "openclaw-canonical-config-agent/1", **(headers or {})},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(262_144)
            data = json.loads(raw.decode("utf-8")) if raw else {}
            if not isinstance(data, dict):
                raise BridgeError("response_not_object")
            return response.status, data
    except urllib.error.HTTPError as error:
        raw = error.read(262_144)
        try:
            data = json.loads(raw.decode("utf-8")) if raw else {}
        except Exception:
            data = {}
        if not isinstance(data, dict):
            data = {}
        return error.code, data
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as error:
        raise BridgeError(f"network_or_json_error:{type(error).__name__}") from error


def load_cached_publishable_key() -> str:
    try:
        data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        key = data.get("supabase", {}).get("publishable_key")
        return key if isinstance(key, str) else ""
    except Exception:
        return ""


def atomic_write(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def refresh_session(refresh_token: str, publishable_key: str) -> tuple[str, str]:
    if not refresh_token or not publishable_key:
        raise BridgeError("refresh_material_unavailable")
    status, data = request_json(
        f"{SUPABASE_URL}/auth/v1/token?grant_type=refresh_token",
        method="POST",
        headers={"apikey": publishable_key, "Content-Type": "application/json"},
        body={"refresh_token": refresh_token},
    )
    if status != 200:
        raise BridgeError(f"session_refresh_failed:{status}")
    access = data.get("access_token")
    new_refresh = data.get("refresh_token")
    if not isinstance(access, str) or not access or not isinstance(new_refresh, str) or not new_refresh:
        raise BridgeError("session_refresh_response_invalid")
    return access, new_refresh


def save_session(access: str, refresh: str) -> None:
    content = "\n".join(
        [
            f"SUPABASE_URL={shlex.quote(SUPABASE_URL)}",
            f"PI_ACCESS_TOKEN={shlex.quote(access)}",
            f"PI_REFRESH_TOKEN={shlex.quote(refresh)}",
            f"OPENCLAW_RUNTIME_DIR={shlex.quote(str(RUNTIME_DIR))}",
            f"CANONICAL_CONFIG_PATH={shlex.quote(str(CONFIG_PATH))}",
            f"CANONICAL_CLIENT_ENV_PATH={shlex.quote(str(CLIENT_ENV_PATH))}",
            f"SESSION_ENV_PATH={shlex.quote(str(SESSION_ENV_PATH))}",
            "",
        ]
    )
    atomic_write(SESSION_ENV_PATH, content, 0o600)


def fetch_config(access_token: str) -> tuple[int, dict[str, Any]]:
    return request_json(
        f"{SUPABASE_URL}/functions/v1/canonical-client-config",
        headers={"Authorization": f"Bearer {access_token}"},
    )


def validate_config(data: dict[str, Any]) -> None:
    if data.get("ok") is not True:
        raise BridgeError("config_not_ok")
    if not isinstance(data.get("config_version"), int) or data["config_version"] < 2:
        raise BridgeError("config_version_too_old")

    supabase = data.get("supabase")
    vercel = data.get("vercel")
    policy = data.get("policy")
    if not isinstance(supabase, dict) or not isinstance(vercel, dict) or not isinstance(policy, dict):
        raise BridgeError("config_sections_missing")

    checks = [
        supabase.get("project_ref") == EXPECTED_PROJECT_REF,
        supabase.get("url") == EXPECTED_URL,
        supabase.get("publishable_key_name") == "default",
        supabase.get("publishable_key_type") == "publishable",
        isinstance(supabase.get("publishable_key"), str) and supabase["publishable_key"].startswith("sb_publishable_"),
        supabase.get("legacy_anon_fallback_enabled") is False,
        supabase.get("server_secret_returned") is False,
        vercel.get("canonical_auth_mode") == "connected_connector",
        vercel.get("team_id") == EXPECTED_VERCEL_TEAM,
        vercel.get("raw_token_fallback_enabled") is False,
        vercel.get("deploy_enabled") is False,
        policy.get("paid_api_fallback") is False,
        policy.get("external_write_actions") is False,
        policy.get("public_shell_execution") is False,
        policy.get("telegram_single_poller_enforced") is True,
        policy.get("raw_secret_values_returned") is False,
        policy.get("intended_consumer") == "pi-gateway-client",
    ]
    if not all(checks):
        raise BridgeError("config_policy_invariant_failed")


def save_config(data: dict[str, Any]) -> None:
    atomic_write(CONFIG_PATH, json.dumps(data, ensure_ascii=False, indent=2) + "\n", 0o600)
    supabase = data["supabase"]
    client_env = "\n".join(
        [
            f"SUPABASE_URL={shlex.quote(supabase['url'])}",
            f"SUPABASE_PROJECT_REF={shlex.quote(supabase['project_ref'])}",
            f"SUPABASE_PUBLISHABLE_KEY={shlex.quote(supabase['publishable_key'])}",
            "SUPABASE_LEGACY_ANON_FALLBACK=0",
            "VERCEL_CANONICAL_AUTH_MODE=connected_connector",
            f"VERCEL_TEAM_ID={EXPECTED_VERCEL_TEAM}",
            "VERCEL_RAW_TOKEN_FALLBACK=0",
            "VERCEL_DEPLOY_ENABLED=0",
            "PAID_API_FALLBACK=0",
            "",
        ]
    )
    atomic_write(CLIENT_ENV_PATH, client_env, 0o600)


def main() -> int:
    if SUPABASE_URL != EXPECTED_URL:
        raise BridgeError("unexpected_supabase_url")

    access = ACCESS_TOKEN
    status, data = fetch_config(access) if access else (401, {})
    refreshed = False

    if status == 401 and REFRESH_TOKEN:
        publishable = load_cached_publishable_key() or env("SUPABASE_PUBLISHABLE_KEY")
        access, new_refresh = refresh_session(REFRESH_TOKEN, publishable)
        save_session(access, new_refresh)
        status, data = fetch_config(access)
        refreshed = True

    if status != 200:
        raise BridgeError(f"canonical_config_http_{status}")

    validate_config(data)
    save_config(data)
    print("RESULT=CANONICAL_CONFIG_READY")
    print(f"CONFIG_VERSION={data['config_version']}")
    print(f"SESSION_REFRESHED={'YES' if refreshed else 'NO'}")
    print(f"CONFIG_PATH={CONFIG_PATH}")
    print(f"CLIENT_ENV_PATH={CLIENT_ENV_PATH}")
    print("KEY_VALUES_PRINTED=NO")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BridgeError as error:
        print(f"RESULT=BLOCKED:{error}")
        print("KEY_VALUES_PRINTED=NO")
        raise SystemExit(1)
