#!/usr/bin/env python3
"""Relay a bounded, secret-free OpenClaw control snapshot to LangSmith."""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import sys
import uuid
from typing import Any

import requests
from langsmith import Client

SUPABASE_URL = os.environ.get(
    "SUPABASE_URL", "https://dpllasnpfskyyyzebyal.supabase.co"
).rstrip("/")
SUPABASE_PUBLISHABLE_KEY = os.environ.get("SUPABASE_PUBLISHABLE_KEY", "").strip()
PROJECT = os.environ.get(
    "LANGSMITH_PROJECT", "openclaw-external-orchestrator"
).strip()
RECEIPT_PATH = pathlib.Path(
    os.environ.get(
        "LANGSMITH_RELAY_RECEIPT_PATH",
        "receipts/langsmith-trace-relay.json",
    )
)
RUN_ID = os.environ.get("GITHUB_RUN_ID", f"local-{uuid.uuid4()}")

ALLOWED_CONTROL_KEYS = {
    "state",
    "external_owner_ready",
    "rollback_ready",
    "n8n_healthy",
    "local_scheduler_disable_armed",
    "local_scheduler_shutdown_state",
    "registered_nodes",
    "online_nodes",
    "queue_queued",
    "queue_claimed",
    "secret_values_included",
}


def safe_snapshot() -> dict[str, Any]:
    if not SUPABASE_PUBLISHABLE_KEY:
        raise RuntimeError("supabase_publishable_key_missing")
    response = requests.post(
        f"{SUPABASE_URL}/rest/v1/rpc/bridge_external_orchestrator_state_v1",
        headers={
            "apikey": SUPABASE_PUBLISHABLE_KEY,
            "content-type": "application/json",
            "accept": "application/json",
            "user-agent": "openclaw-langsmith-trace-relay/1",
        },
        json={},
        timeout=30,
    )
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, dict):
        raise RuntimeError("control_snapshot_invalid")
    if payload.get("secret_values_included") is True:
        raise RuntimeError("secret_boundary_failed")
    return {key: payload.get(key) for key in ALLOWED_CONTROL_KEYS if key in payload}


def write_receipt(payload: dict[str, Any]) -> None:
    RECEIPT_PATH.parent.mkdir(parents=True, exist_ok=True)
    RECEIPT_PATH.write_text(
        json.dumps(
            {**payload, "secret_values_included": False},
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def run() -> int:
    started = dt.datetime.now(dt.timezone.utc)
    snapshot = safe_snapshot()
    client = Client()
    trace_id = uuid.uuid4()
    client.create_run(
        id=trace_id,
        name="openclaw-external-orchestration-heartbeat",
        run_type="chain",
        inputs={
            "source": "github_actions",
            "github_run_id": RUN_ID,
            "control": snapshot,
        },
        start_time=started,
        project_name=PROJECT,
        tags=["openclaw", "external-orchestration", "heartbeat"],
        extra={
            "metadata": {
                "runtime": "github_actions",
                "n8n_primary": True,
                "supabase_checkpoint": True,
                "llm_called": False,
                "secret_values_included": False,
            }
        },
    )
    outcome = {
        "external_owner_ready": bool(snapshot.get("external_owner_ready")),
        "rollback_ready": bool(snapshot.get("rollback_ready")),
        "n8n_healthy": bool(snapshot.get("n8n_healthy")),
        "online_nodes": int(snapshot.get("online_nodes") or 0),
        "native_cron_killswitch_state": snapshot.get(
            "local_scheduler_shutdown_state", "unknown"
        ),
        "llm_called": False,
        "secret_values_included": False,
    }
    client.update_run(
        trace_id,
        outputs=outcome,
        end_time=dt.datetime.now(dt.timezone.utc),
    )
    receipt = {
        "result": "langsmith_trace_submitted",
        "github_run_id": RUN_ID,
        "project": PROJECT,
        "trace_id": str(trace_id),
        "oauth_profile_used": bool(os.environ.get("LANGSMITH_CONFIG_FILE")),
        "langsmith_tracing_enabled": True,
        "control": snapshot,
        "outputs": outcome,
    }
    write_receipt(receipt)
    print(
        "LANGSMITH_TRACE_SUBMITTED "
        f"project={PROJECT} trace_id={trace_id} receipt={RECEIPT_PATH}"
    )
    return 0


def main() -> int:
    try:
        return run()
    except Exception as exc:
        code = "".join(
            ch if ch.isalnum() or ch in "._:-" else "_"
            for ch in f"{type(exc).__name__}:{exc}"
        )[:240]
        write_receipt(
            {
                "result": "langsmith_trace_failed",
                "github_run_id": RUN_ID,
                "error_code": code,
                "langsmith_tracing_enabled": False,
            }
        )
        print(f"LANGSMITH_TRACE_FAILED error={code}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
