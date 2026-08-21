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
TRACE_PATH = Path(
    os.environ.get(
        "ORCHESTRATOR_TRACE_PATH",
        "receipts/external-langgraph-trace.jsonl",
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
TRACE_LIMIT = 64


class TraceEvent(TypedDict, total=False):
    seq: int
    node: str
    outcome: str
    timestamp: float
    duration_ms: int
    metadata: dict[str, Any]


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
    trace: list[TraceEvent]
    started_at: float
    completed_at: float


def _safe_error(exc: BaseException) -> str:
    text = f"{type(exc).__name__}:{exc}"
    return "".join(ch if ch.isalnum() or ch in "._:-" else "_" for ch in text)[:240]


def _bounded_metadata(value: dict[str, Any] | None) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for key, item in (value or {}).items():
        safe_key = "".join(
            character
            for character in str(key)
            if character.isalnum() or character in "._-"
        )[:80]
        if not safe_key:
            continue
        if isinstance(item, bool) or item is None:
            output[safe_key] = item
        elif isinstance(item, int):
            output[safe_key] = item
        elif isinstance(item, float):
            output[safe_key] = round(item, 6)
        elif isinstance(item, str):
            output[safe_key] = "".join(
                character
                if character.isalnum() or character in " ._:/@-"
                else "_"
                for character in item
            )[:240]
    return output


def _append_trace(
    state: OrchestratorState,
    node: str,
    outcome: str,
    *,
    started_at: float,
    metadata: dict[str, Any] | None = None,
) -> list[TraceEvent]:
    previous = list(state.get("trace", []))[-(TRACE_LIMIT - 1) :]
    event: TraceEvent = {
        "seq": len(previous) + 1,
        "node": node[:80],
        "outcome": outcome[:80],
        "timestamp": time.time(),
        "duration_ms": max(0, int((time.time() - started_at) * 1000)),
        "metadata": _bounded_metadata(metadata),
    }
    return [*previous, event]


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
            "user-agent": "github-langgraph-openclaw-orchestrator/2",
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
    started_at = time.time()
    try:
        control = read_control_runnable.invoke({})
        return {
            **state,
            "control": control,
            "trace": _append_trace(
                state,
                "read_control",
                "succeeded",
                started_at=started_at,
                metadata={
                    "external_owner_ready": bool(
                        control.get("external_owner_ready")
                    ),
                    "rollback_ready": bool(control.get("rollback_ready")),
                    "n8n_healthy": bool(control.get("n8n_healthy")),
                    "registered_nodes": int(
                        control.get("registered_nodes") or 0
                    ),
                    "online_nodes": int(control.get("online_nodes") or 0),
                },
            ),
        }
    except Exception as exc:
        error = _safe_error(exc)
        return {
            **state,
            "error": error,
            "control": {
                "state": "unavailable",
                "external_owner_ready": False,
                "rollback_ready": False,
                "n8n_healthy": False,
                "secret_values_included": False,
            },
            "trace": _append_trace(
                state,
                "read_control",
                "failed",
                started_at=started_at,
                metadata={"error": error},
            ),
        }


def decide(state: OrchestratorState) -> OrchestratorState:
    started_at = time.time()
    control = state.get("control", {})
    if state.get("error"):
        decision = "watchdog"
        rationale = "control_read_failed_emit_recovery_signal"
    elif not bool(control.get("n8n_healthy")):
        decision = "watchdog"
        rationale = "n8n_heartbeat_stale_supabase_failover_required"
    elif (
        bool(control.get("external_owner_ready"))
        and bool(control.get("rollback_ready"))
        and not bool(control.get("local_scheduler_disable_armed"))
    ):
        decision = "arm_local_scheduler_disable"
        rationale = "external_owner_and_rollback_ready"
    elif (
        bool(control.get("external_owner_ready"))
        and bool(control.get("local_scheduler_disable_armed"))
    ):
        decision = "observe"
        rationale = "external_owner_ready_local_shutdown_already_armed"
    else:
        decision = "no_op"
        rationale = "no_safe_mutating_action_from_read_only_runtime"

    return {
        **state,
        "decision": decision,
        "rationale": rationale,
        "trace": _append_trace(
            state,
            "decide",
            "succeeded",
            started_at=started_at,
            metadata={
                "decision": decision,
                "rationale": rationale,
            },
        ),
    }


def finalize(state: OrchestratorState) -> OrchestratorState:
    started_at = time.time()
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
        "langgraph_persistent_checkpoint": True,
        "langchain_active": True,
        "langsmith_configured": LANGSMITH_CONFIGURED,
        "supabase_trace_fallback_active": True,
        "llm_called": False,
        "mutation_performed": False,
        "secret_values_included": False,
    }
    trace = _append_trace(
        state,
        "finalize",
        "succeeded",
        started_at=started_at,
        metadata={
            "decision": decision,
            "langsmith_configured": LANGSMITH_CONFIGURED,
            "supabase_trace_fallback_active": True,
        },
    )
    return {
        **state,
        "result": result,
        "trace": trace,
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


def _write_trace(events: list[TraceEvent]) -> None:
    TRACE_PATH.parent.mkdir(parents=True, exist_ok=True)
    with TRACE_PATH.open("w", encoding="utf-8") as handle:
        for event in events[-TRACE_LIMIT:]:
            handle.write(
                json.dumps(
                    {
                        "schema": "openclaw.external-orchestrator-trace/v1",
                        "run_id": RUN_ID,
                        "event_name": EVENT_NAME,
                        "thread_id": THREAD_ID,
                        **event,
                        "langsmith_configured": LANGSMITH_CONFIGURED,
                        "supabase_checkpoint_fallback": True,
                        "secret_values_included": False,
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
                + "\n"
            )


@traceable(
    name="openclaw-external-langgraph-orchestrator",
    run_type="chain",
    metadata={
        "runtime": "github_actions",
        "llm_called": False,
        "supabase_trace_fallback": True,
        "secret_values_included": False,
    },
)
def run() -> dict[str, Any]:
    CHECKPOINT_PATH.parent.mkdir(parents=True, exist_ok=True)
    RECEIPT_PATH.parent.mkdir(parents=True, exist_ok=True)

    initial: OrchestratorState = {
        "run_id": RUN_ID,
        "event_name": EVENT_NAME,
        "trace": [],
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

    trace = list(final.get("trace", []))[-TRACE_LIMIT:]
    _write_trace(trace)
    receipt = {
        "schema": "openclaw.external-langgraph-orchestrator/v2",
        "run_id": RUN_ID,
        "event_name": EVENT_NAME,
        "thread_id": THREAD_ID,
        "decision": final.get("decision", "no_op"),
        "rationale": final.get("rationale", ""),
        "result": final.get("result", {}),
        "error": final.get("error"),
        "trace": trace,
        "trace_event_count": len(trace),
        "trace_path": str(TRACE_PATH),
        "checkpoint_path": str(CHECKPOINT_PATH),
        "langsmith_configured": LANGSMITH_CONFIGURED,
        "langsmith_tracing_enabled": (
            LANGSMITH_CONFIGURED
            and os.environ.get("LANGSMITH_TRACING", "").lower() == "true"
        ),
        "supabase_trace_fallback_active": True,
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
        error = _safe_error(exc)
        receipt = {
            "schema": "openclaw.external-langgraph-orchestrator/v2",
            "run_id": RUN_ID,
            "event_name": EVENT_NAME,
            "decision": "watchdog",
            "error": error,
            "langgraph_active": True,
            "langchain_active": True,
            "langsmith_configured": LANGSMITH_CONFIGURED,
            "supabase_trace_fallback_active": True,
            "llm_called": False,
            "mutation_performed": False,
            "secret_values_included": False,
        }
        RECEIPT_PATH.parent.mkdir(parents=True, exist_ok=True)
        RECEIPT_PATH.write_text(
            json.dumps(receipt, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        _write_trace(
            [
                {
                    "seq": 1,
                    "node": "orchestrator",
                    "outcome": "failed",
                    "timestamp": time.time(),
                    "duration_ms": 0,
                    "metadata": {"error": error},
                }
            ]
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
        f"supabase_trace_fallback={str(receipt.get('supabase_trace_fallback_active', False)).lower()} "
        f"trace_events={receipt.get('trace_event_count', 0)} "
        f"receipt={RECEIPT_PATH}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
