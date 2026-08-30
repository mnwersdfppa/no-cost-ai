#!/usr/bin/env python3
"""Fail-closed Raspberry Pi client for the Supabase emergency bridge.

The client reads only a short-lived Pi user JWT from its environment. It never
reads or prints the Supabase service-role key, provider secrets, OAuth tokens,
or the selected publishable-key value.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from typing import Any

BASE = os.environ.get("SUPABASE_URL", "").rstrip("/")
TOKEN = os.environ.get("PI_ACCESS_TOKEN", "")
NODE_NAME = os.environ.get("OPENCLAW_BRIDGE_NODE_NAME", "raspberry-pi5")
TIMEOUT_SECONDS = 20
PROJECT_REF = "dpllasnpfskyyyzebyal"
VERCEL_TEAM_ID = "team_sa2sEffAlVXK6b9lsweDm6QL"


def fail(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def command_ok(command: list[str], timeout: int = 8) -> bool:
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
            env={**os.environ, "NO_COLOR": "1"},
        )
        return completed.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def local_capabilities() -> dict[str, Any]:
    adb_devices = 0
    try:
        result = subprocess.run(
            ["adb", "devices"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if result.returncode == 0:
            adb_devices = sum(
                1
                for line in result.stdout.splitlines()[1:]
                if line.strip().endswith("\tdevice")
            )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return {
        "openclaw_cli": command_ok(["openclaw", "--version"]),
        "gateway_healthy": command_ok(["openclaw", "gateway", "status"]),
        "openclaw_status_healthy": command_ok(["openclaw", "status"]),
        "ollama_healthy": command_ok(
            ["curl", "-fsS", "--max-time", "3", "http://127.0.0.1:11434/api/version"]
        ),
        "authorized_adb_devices": adb_devices,
        "paid_api_fallback_requested": False,
        "phone_write_requested": False,
        "telegram_poller_created": False,
    }


def execution_key(prefix: str, bucket_seconds: int = 300) -> str:
    bucket = int(time.time() // bucket_seconds)
    return f"{prefix}-{NODE_NAME}-{bucket}"


def verify_response_boundary(path: str, payload: dict[str, Any]) -> None:
    if path == "credential-readiness":
        for key in ("values_returned", "prefixes_returned", "hashes_returned", "lengths_returned"):
            if payload.get(key) is not False:
                fail(f"CREDENTIAL_BOUNDARY_NOT_CONFIRMED={key}", 34)
        return

    if path == "canonical-client-config":
        policy = payload.get("policy")
        if not isinstance(policy, dict):
            fail("CANONICAL_POLICY_MISSING", 35)
        for key in ("server_secret_returned", "oauth_token_returned", "vercel_raw_token_returned"):
            if policy.get(key) is not False:
                fail(f"CANONICAL_SECRET_BOUNDARY_NOT_CONFIRMED={key}", 35)
        return

    if payload.get("values_exposed") is not False:
        fail("BRIDGE_SECRET_BOUNDARY_NOT_CONFIRMED", 34)


def request(path: str, body: dict[str, Any]) -> dict[str, Any]:
    if not BASE.startswith("https://"):
        fail("BLOCKED=HTTPS_SUPABASE_URL_REQUIRED", 20)
    if len(TOKEN) < 20:
        fail("BLOCKED=PI_ACCESS_TOKEN_REQUIRED", 21)

    encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        f"{BASE}/functions/v1/{path}",
        data=encoded,
        method="POST",
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "openclaw-emergency-bridge-pi/2",
            "X-Correlation-Id": str(body.get("correlation_id", "")),
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
        if exc.code == 429:
            fail("BRIDGE_RATE_LIMITED=HTTP_429", 31)
        fail(f"BRIDGE_REQUEST_REJECTED=HTTP_{exc.code}", 31)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        fail(f"BRIDGE_UNREACHABLE={type(exc).__name__}", 32)

    if not isinstance(payload, dict):
        fail("BRIDGE_INVALID_RESPONSE", 33)
    if payload.get("ok") is not True:
        fail(f"BRIDGE_RESPONSE_NOT_OK={payload.get('error', 'unknown')}", 33)
    verify_response_boundary(path, payload)
    return payload


def action_heartbeat(correlation_id: str) -> None:
    capabilities = local_capabilities()
    status = "online" if capabilities["gateway_healthy"] else "degraded"
    payload = request(
        "emergency-bridge",
        {
            "action": "heartbeat",
            "execution_key": execution_key("heartbeat"),
            "correlation_id": correlation_id,
            "node_name": NODE_NAME,
            "node_type": "raspberry_pi",
            "status": status,
            "capabilities": capabilities,
            "metadata": {
                "source": "systemd_user_timer",
                "secret_values_included": False,
            },
        },
    )
    print(f"HEARTBEAT=PASS status={status} duplicate={bool(payload.get('duplicate'))}")


def action_status(correlation_id: str) -> None:
    payload = request(
        "emergency-bridge",
        {
            "action": "status",
            "execution_key": f"status-{uuid.uuid4()}",
            "correlation_id": correlation_id,
        },
    )
    controls = {
        row.get("control_key"): row.get("enabled")
        for row in payload.get("controls", [])
        if isinstance(row, dict)
    }
    required = {
        "paid_api_fallback": False,
        "external_write_actions": False,
        "phone_write_actions": False,
        "public_shell_execution": False,
        "telegram_single_poller_enforced": True,
        "supabase_control_plane": True,
    }
    for key, expected in required.items():
        if controls.get(key) is not expected:
            fail(f"STATUS_CONTROL_MISMATCH={key}", 40)
    print("STATUS=PASS paid_api=OFF writes=OFF public_shell=OFF single_poller=ON")


def action_queue(correlation_id: str) -> None:
    payload = request(
        "emergency-bridge",
        {
            "action": "queue_status",
            "execution_key": f"queue-{uuid.uuid4()}",
            "correlation_id": correlation_id,
        },
    )
    print("QUEUE_STATUS=PASS counts=" + json.dumps(payload.get("counts", {}), separators=(",", ":")))


def action_policy(correlation_id: str, integration: str, operation: str) -> None:
    payload = request(
        "emergency-bridge",
        {
            "action": "policy_check",
            "execution_key": f"policy-{uuid.uuid4()}",
            "correlation_id": correlation_id,
            "integration": integration,
            "operation": operation,
        },
    )
    decision = payload.get("decision")
    if not isinstance(decision, dict):
        fail("POLICY_DECISION_MISSING", 41)
    print(
        "POLICY=PASS "
        + json.dumps(
            {
                "integration": integration,
                "operation": operation,
                "allowed": decision.get("allowed"),
                "approval_required": decision.get("approval_required"),
                "reason": decision.get("reason"),
            },
            separators=(",", ":"),
        )
    )


def action_credentials(correlation_id: str) -> None:
    payload = request(
        "credential-readiness",
        {
            "execution_key": execution_key("credential-readiness", 86400),
            "correlation_id": correlation_id,
        },
    )
    present = [
        row.get("integration")
        for row in payload.get("results", [])
        if isinstance(row, dict) and row.get("present_in_edge_runtime") is True
    ]
    print("CREDENTIAL_READINESS=PASS present_integrations=" + json.dumps(present, separators=(",", ":")))


def action_config(correlation_id: str) -> None:
    payload = request(
        "canonical-client-config",
        {
            "execution_key": execution_key("canonical-config", 21600),
            "correlation_id": correlation_id,
        },
    )
    supabase = payload.get("supabase")
    vercel = payload.get("vercel")
    policy = payload.get("policy")
    if not all(isinstance(item, dict) for item in (supabase, vercel, policy)):
        fail("CANONICAL_CONFIG_SHAPE_INVALID", 42)
    assert isinstance(supabase, dict)
    assert isinstance(vercel, dict)
    assert isinstance(policy, dict)
    if supabase.get("project_ref") != PROJECT_REF:
        fail("CANONICAL_PROJECT_REF_MISMATCH", 42)
    if not isinstance(supabase.get("publishable_key"), str) or not supabase["publishable_key"]:
        fail("CANONICAL_PUBLISHABLE_KEY_MISSING", 42)
    if supabase.get("publishable_key_type") != "publishable":
        fail("CANONICAL_KEY_IS_NOT_MODERN_PUBLISHABLE", 42)
    if supabase.get("legacy_anon_fallback_enabled") is not False:
        fail("LEGACY_ANON_FALLBACK_ENABLED", 42)
    if vercel.get("team_id") != VERCEL_TEAM_ID:
        fail("VERCEL_TEAM_MISMATCH", 42)
    if vercel.get("raw_token_fallback_enabled") is not False:
        fail("VERCEL_RAW_TOKEN_FALLBACK_ENABLED", 42)
    if vercel.get("deployment_enabled") is not False:
        fail("VERCEL_DEPLOYMENT_UNEXPECTEDLY_ENABLED", 42)
    if policy.get("paid_api_fallback") is not False:
        fail("PAID_API_FALLBACK_ENABLED", 42)
    if policy.get("telegram_single_poller_enforced") is not True:
        fail("SINGLE_TELEGRAM_POLLER_NOT_ENFORCED", 42)
    print("CANONICAL_CONFIG=PASS modern_publishable=SELECTED vercel_deploy=OFF key_value_printed=NO")


def action_command_status(correlation_id: str) -> None:
    payload = request(
        "command-center",
        {
            "action": "command_status",
            "execution_key": f"command-status-{uuid.uuid4()}",
            "correlation_id": correlation_id,
        },
    )
    status = payload.get("status")
    if not isinstance(status, dict):
        fail("COMMAND_CENTER_STATUS_MISSING", 43)
    print("COMMAND_CENTER_STATUS=PASS values_exposed=NO")


def action_route(correlation_id: str, capability: str, risk_tier: int) -> None:
    if risk_tier < 0 or risk_tier > 4:
        fail("RISK_TIER_MUST_BE_0_TO_4", 2)
    payload = request(
        "emergency-bridge",
        {
            "action": "resolve_route",
            "execution_key": f"route-{uuid.uuid4()}",
            "correlation_id": correlation_id,
            "capability": capability,
            "risk_tier": risk_tier,
        },
    )
    route = payload.get("route")
    if not isinstance(route, dict):
        fail("ROUTE_DECISION_MISSING", 44)
    if route.get("integration") == "openai":
        fail("PAID_OPENAI_ROUTE_SELECTED", 44)
    decision = route.get("decision")
    if decision not in ("route_selected", "stop_no_eligible_route"):
        fail("ROUTE_DECISION_INVALID", 44)
    print(
        "ROUTE=PASS "
        + json.dumps(
            {
                "capability": capability,
                "risk_tier": risk_tier,
                "route_key": route.get("route_key"),
                "integration": route.get("integration"),
                "decision": decision,
            },
            separators=(",", ":"),
        )
    )


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    correlation_id = str(uuid.uuid4())

    if action == "heartbeat":
        action_heartbeat(correlation_id)
    elif action == "status":
        action_status(correlation_id)
    elif action == "queue":
        action_queue(correlation_id)
    elif action == "policy":
        action_policy(
            correlation_id,
            sys.argv[2] if len(sys.argv) > 2 else "openai",
            sys.argv[3] if len(sys.argv) > 3 else "chat",
        )
    elif action == "credentials":
        action_credentials(correlation_id)
    elif action == "config":
        action_config(correlation_id)
    elif action == "command-status":
        action_command_status(correlation_id)
    elif action == "route":
        capability = sys.argv[2] if len(sys.argv) > 2 else "model_chat"
        try:
            risk_tier = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        except ValueError:
            fail("RISK_TIER_MUST_BE_INTEGER", 2)
        action_route(correlation_id, capability, risk_tier)
    else:
        fail(
            "SUPPORTED_ACTIONS=status|heartbeat|queue|policy|credentials|config|command-status|route",
            2,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
