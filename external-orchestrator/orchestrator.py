from __future__ import annotations

import json
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Literal, TypedDict

import requests
from langchain_core.runnables import RunnableLambda
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.graph import END, START, StateGraph
from langsmith import traceable

SUPABASE_URL = os.environ.get(
    "SUPABASE_URL",
    "https://dpllasnpfskyyyzebyal.supabase.co",
).rstrip("/")
SUPABASE_PUBLISHABLE_KEY = os.environ.get("SUPABASE_PUBLISHABLE_KEY", "").strip()
CHECKPOINT_PATH = Path(
    os.environ.get(
        "LANGGRAPH_CHECKPOINT_PATH",
        ".cache/langgraph/external-orchestrator.sqlite",
    )
)
RECEIPT_PATH = Path(
    os.environ.get(
        "ORCHESTRATOR_RECEIPT_PATH",
        "receipts/external-langgraph-orchestrator.json",
    )
)
THREAD_ID = os.environ.get(
    "LANGGRAPH_THREAD_ID",
    "openclaw-external-orchestrator-v1",
)
RUN_ID = os.environ.get("GITHUB_RUN_ID", f"local-{uuid.uuid4()}")
EVENT_NAME = os.environ.get("GITHUB_EVENT_NAME", "local")
DRY_RUN = os.environ.get("ORCHESTRATOR_DRY_RUN", "false").lower() == "true"
LANGSMITH_CONFIGURED = bool(os.environ.get("LANGSMITH_API_KEY", "").strip())


class OrchestratorState(TypedDict, total=False):
    run_id: str
    event_name: str
    control: dict[str, Any]
    decision: Literal[
        "observe",
        "watchdog",
        "arm_local_scheduler_disable",
        "no_op",
    ]
    rationale: str
    result: dict[str, Any]
    error: str
    started_at: float
    completed_at: float


def _safe_error(exc: BaseException) -> str:
    text = f"{type(exc).__name__}:{exc}"
    return "".join(ch if ch.isalnum() or ch in "._:-" else "_" for ch in text)[:240]


def _safe_control_snapshot() -> dict[str, Any]:
    if DRY_RUN:
        return {
            "state": "external_owner_ready",
            "external_owner_ready": True,
            "rollback_ready": True,
            "n8n_healthy": True,
            "local_scheduler_disable_armed": True,
            "local_scheduler_shutdown_state": "armed",
            "registered_nodes": 0,
            "online_nodes": 0,
            "queue_queued": 1,
            "queue_claimed": 0,
            "secret_values_included": False,
            "dry_run": True,
        }

    if not SUPABASE_PUBLISHABLE_KEY:
        raise RuntimeError("supabase_publishable_key_missing")

    endpoint = (
        f"{SUPABASE_URL}/rest/v1/rpc/"
        "bridge_external_orchestrator_state_v1"
    )
    response = requests.post(
        endpoint,
        headers={
            "apikey": SUPABASE_PUBLISHABLE_KEY,
            "content-type": "application/json",
            "accept": "application/json",
            "user-agent": "github-langgraph-openclaw-orchestrator/1",
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
    return payload


read_control_runnable = RunnableLambda(lambda _: _safe_control_snapshot())


def read_control(state: OrchestratorState) -> OrchestratorState:
    try:
        control = read_control_runnable.invoke({})
        return {
            **state,
            "control": control,
        }
    except Exception as exc:
        return {
            **state,
            "error": _safe_error(exc),
            "control": {
                "state": "unavailable",
                "external_owner_ready": False,
                "rollback_ready": False,
                "n8n_healthy": False,
                "secret_values_included": False,
            },
        }


def decide(state: OrchestratorState) -> OrchestratorState:
    control = state.get("control", {})
    if state.get("error"):
        return {
            **state,
            "decision": "watchdog",
            "rationale": "control_read_failed_emit_recovery_signal",
        }

    if not bool(control.get("n8n_healthy")):
        return {
            **state,
            "decision": "watchdog",
            "rationale": "n8n_heartbeat_stale_supabase_failover_required",
        }

    if (
        bool(control.get("external_owner_ready"))
        and bool(control.get("rollback_ready"))
        and not bool(control.get("local_scheduler_disable_armed"))
    ):
        return {
            **state,
            "decision": "arm_local_scheduler_disable",
            "rationale": "external_owner_and_rollback_ready",
        }

    if (
        bool(control.get("external_owner_ready"))
        and bool(control.get("local_scheduler_disable_armed"))
    ):
        return {
            **state,
            "decision": "observe",
            "rationale": "external_owner_ready_local_shutdown_already_armed",
        }

    return {
        **state,
        "decision": "no_op",
        "rationale": "no_safe_mutating_action_from_read_only_runtime",
    }


def finalize(state: OrchestratorState) -> OrchestratorState:
    decision = state.get("decision", "no_op")
    control = state.get("control", {})
    result = {
        "decision": decision,
        "rationale": state.get("rationale", ""),
        "external_owner_ready": bool(control.get("external_owner_ready")),
        "rollback_ready": bool(control.get("rollback_ready")),
        "n8n_healthy": bool(control.get("n8n_healthy")),
        "local_scheduler_disable_armed": bool(
            control.get("local_scheduler_disable_armed")
        ),
        "local_scheduler_shutdown_state": control.get(
            "local_scheduler_shutdown_state",
            "unknown",
        ),
        "registered_nodes": int(control.get("registered_nodes") or 0),
        "online_nodes": int(control.get("online_nodes") or 0),
        "queue_queued": int(control.get("queue_queued") or 0),
        "queue_claimed": int(control.get("queue_claimed") or 0),
        "langgraph_active": True,
        "langchain_active": True,
        "langsmith_configured": LANGSMITH_CONFIGURED,
        "llm_called": False,
        "mutation_performed": False,
        "secret_values_included": False,
    }
    return {
        **state,
        "result": result,
        "completed_at": time.time(),
    }


def route_after_read(
    state: OrchestratorState,
) -> Literal["decide", "finalize"]:
    if state.get("control"):
        return "decide"
    return "finalize"


def build_graph(checkpointer: SqliteSaver):
    graph = StateGraph(OrchestratorState)
    graph.add_node("read_control", read_control)
    graph.add_node("decide", decide)
    graph.add_node("finalize", finalize)
    graph.add_edge(START, "read_control")
    graph.add_conditional_edges(
        "read_control",
        route_after_read,
        {"decide": "decide", "finalize": "finalize"},
    )
    graph.add_edge("decide", "finalize")
    graph.add_edge("finalize", END)
    return graph.compile(checkpointer=checkpointer)


@traceable(
    name="openclaw-external-langgraph-orchestrator",
    run_type="chain",
    metadata={
        "runtime": "github_actions",
        "llm_called": False,
        "secret_values_included": False,
    },
)
def run() -> dict[str, Any]:
    CHECKPOINT_PATH.parent.mkdir(parents=True, exist_ok=True)
    RECEIPT_PATH.parent.mkdir(parents=True, exist_ok=True)

    initial: OrchestratorState = {
        "run_id": RUN_ID,
        "event_name": EVENT_NAME,
        "started_at": time.time(),
    }
    config = {
        "configurable": {
            "thread_id": THREAD_ID,
            "checkpoint_ns": "",
        }
    }

    with SqliteSaver.from_conn_string(str(CHECKPOINT_PATH)) as checkpointer:
        app = build_graph(checkpointer)
        final = app.invoke(initial, config=config)

    receipt = {
        "schema": "openclaw.external-langgraph-orchestrator/v1",
        "run_id": RUN_ID,
        "event_name": EVENT_NAME,
        "thread_id": THREAD_ID,
        "decision": final.get("decision", "no_op"),
        "rationale": final.get("rationale", ""),
        "result": final.get("result", {}),
        "error": final.get("error"),
        "checkpoint_path": str(CHECKPOINT_PATH),
        "langsmith_configured": LANGSMITH_CONFIGURED,
        "langsmith_tracing_enabled": (
            LANGSMITH_CONFIGURED
            and os.environ.get("LANGSMITH_TRACING", "").lower() == "true"
        ),
        "dry_run": DRY_RUN,
        "secret_values_included": False,
    }
    RECEIPT_PATH.write_text(
        json.dumps(receipt, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return receipt


def main() -> int:
    try:
        receipt = run()
    except Exception as exc:
        receipt = {
            "schema": "openclaw.external-langgraph-orchestrator/v1",
            "run_id": RUN_ID,
            "event_name": EVENT_NAME,
            "decision": "watchdog",
            "error": _safe_error(exc),
            "langgraph_active": True,
            "langchain_active": True,
            "langsmith_configured": LANGSMITH_CONFIGURED,
            "llm_called": False,
            "mutation_performed": False,
            "secret_values_included": False,
        }
        RECEIPT_PATH.parent.mkdir(parents=True, exist_ok=True)
        RECEIPT_PATH.write_text(
            json.dumps(receipt, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(
            "EXTERNAL_ORCHESTRATOR_DEGRADED "
            f"error={receipt['error']} receipt={RECEIPT_PATH}"
        )
        return 1

    result = receipt.get("result", {})
    print(
        "EXTERNAL_ORCHESTRATOR_READY "
        f"decision={receipt.get('decision')} "
        f"external_owner_ready={str(result.get('external_owner_ready', False)).lower()} "
        f"rollback_ready={str(result.get('rollback_ready', False)).lower()} "
        f"local_scheduler_disable_armed={str(result.get('local_scheduler_disable_armed', False)).lower()} "
        f"langsmith_configured={str(receipt.get('langsmith_configured', False)).lower()} "
        f"receipt={RECEIPT_PATH}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
