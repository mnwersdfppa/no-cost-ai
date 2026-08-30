#!/usr/bin/env python3
"""Verify client-safe canonical configuration from Raspberry Pi.

The script reads only the Pi-local short-lived JWT, validates fail-closed public
configuration, and submits a bounded non-secret SHA-256 receipt to the Supabase
emergency bridge. It never prints the publishable key or any credential value.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from typing import Any, Iterable

BASE = os.environ.get("SUPABASE_URL", "").rstrip("/")
TOKEN = os.environ.get("PI_ACCESS_TOKEN", "")
PROJECT_REF = "dpllasnpfskyyyzebyal"
TIMEOUT_SECONDS = 25


def fail(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def post(function_name: str, body: dict[str, Any], correlation_id: str) -> dict[str, Any]:
    if not BASE.startswith("https://"):
        fail("BLOCKED=HTTPS_SUPABASE_URL_REQUIRED", 20)
    if len(TOKEN) < 20:
        fail("BLOCKED=CURRENT_SHORT_LIVED_PI_JWT_REQUIRED", 21)

    encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        f"{BASE}/functions/v1/{function_name}",
        data=encoded,
        method="POST",
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "openclaw-canonical-config-pi/1",
            "X-Correlation-Id": correlation_id,
            "X-Execution-Key": str(body.get("execution_key", "")),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        exc.read(4096)
        if exc.code in (401, 403):
            fail(f"AUTH_OR_ROLE_REJECTED=HTTP_{exc.code}", 30)
        fail(f"FUNCTION_REJECTED={function_name}:HTTP_{exc.code}", 31)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        fail(f"FUNCTION_UNREACHABLE={function_name}:{type(exc).__name__}", 32)

    if not isinstance(payload, dict):
        fail(f"INVALID_RESPONSE={function_name}", 33)
    return payload


def walk(value: Any) -> Iterable[tuple[str, Any]]:
    if isinstance(value, dict):
        for key, child in value.items():
            yield str(key), child
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def first_value(payload: dict[str, Any], *keys: str) -> Any:
    wanted = {key.lower() for key in keys}
    for key, value in walk(payload):
        if key.lower() in wanted:
            return value
    return None


def require_false(payload: dict[str, Any], *keys: str) -> bool:
    value = first_value(payload, *keys)
    if value is not False:
        fail(f"CANONICAL_CONFIG_FALSE_INVARIANT_FAILED={keys[0]}", 40)
    return False


def require_true(payload: dict[str, Any], *keys: str) -> bool:
    value = first_value(payload, *keys)
    if value is not True:
        fail(f"CANONICAL_CONFIG_TRUE_INVARIANT_FAILED={keys[0]}", 41)
    return True


def main() -> int:
    correlation_id = str(uuid.uuid4())
    execution_key = f"canonical-config-{uuid.uuid4()}"
    payload = post(
        "canonical-client-config",
        {
            "execution_key": execution_key,
            "correlation_id": correlation_id,
            "client": "raspberry-pi5",
        },
        correlation_id,
    )

    serialized = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    if PROJECT_REF not in serialized:
        fail("CANONICAL_PROJECT_REF_MISMATCH", 42)

    evidence = {
        "project_ref": PROJECT_REF,
        "server_secret_returned": require_false(
            payload,
            "server_secret_returned",
            "server_key_returned",
            "service_role_returned",
        ),
        "legacy_anon_fallback_enabled": require_false(
            payload,
            "legacy_anon_fallback_enabled",
            "legacy_anon_fallback",
        ),
        "vercel_raw_token_fallback_enabled": require_false(
            payload,
            "vercel_raw_token_fallback_enabled",
            "raw_token_fallback_enabled",
            "vercel_raw_token_fallback",
        ),
        "paid_api_fallback": require_false(
            payload,
            "paid_api_fallback",
            "paid_api_fallback_enabled",
        ),
        "telegram_single_poller_enforced": require_true(
            payload,
            "telegram_single_poller_enforced",
            "single_telegram_poller_enforced",
        ),
        "client": "raspberry-pi5",
        "credential_values_included": False,
    }

    canonical_evidence = json.dumps(
        evidence,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    evidence_sha256 = hashlib.sha256(canonical_evidence).hexdigest()

    receipt = post(
        "emergency-bridge",
        {
            "action": "completion_receipt",
            "execution_key": f"completion-receipt-{evidence_sha256}",
            "correlation_id": correlation_id,
            "gate_key": "canonical_config_pi_e2e",
            "evidence_sha256": evidence_sha256,
            "evidence": evidence,
        },
        correlation_id,
    )

    if receipt.get("ok") is not True:
        fail("CANONICAL_CONFIG_RECEIPT_REJECTED", 43)
    if receipt.get("values_exposed") is not False:
        fail("RECEIPT_SECRET_BOUNDARY_NOT_CONFIRMED", 44)

    print("CANONICAL_CONFIG_PI_E2E=PASS")
    print(f"EVIDENCE_SHA256={evidence_sha256}")
    print("SERVER_SECRET_RETURNED=NO")
    print("LEGACY_ANON_FALLBACK=OFF")
    print("VERCEL_RAW_TOKEN_FALLBACK=OFF")
    print("PAID_API_FALLBACK=OFF")
    print("TELEGRAM_SINGLE_POLLER=ON")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
