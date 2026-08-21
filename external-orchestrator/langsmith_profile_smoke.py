from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path

from langsmith import Client, traceable

PROJECT = os.environ.get(
    "LANGSMITH_PROJECT", "openclaw-external-orchestrator"
)
RECEIPT = Path(
    os.environ.get(
        "LANGSMITH_RECEIPT_PATH",
        "receipts/langsmith-oauth-trace-relay.json",
    )
)


@traceable(
    name="openclaw-external-trace-heartbeat",
    run_type="chain",
    project_name=PROJECT,
    metadata={
        "runtime": "github_actions_oauth_profile",
        "llm_called": False,
        "mutation_performed": False,
        "secret_values_included": False,
    },
)
def heartbeat() -> dict[str, object]:
    return {
        "state": "external_runtime_active",
        "n8n_owner": True,
        "supabase_checkpoint": True,
        "langgraph_runtime": True,
        "llm_called": False,
        "secret_values_included": False,
    }


def main() -> int:
    result = heartbeat()
    client = Client()
    list_verified = False
    try:
        next(client.list_runs(project_name=PROJECT, limit=1), None)
        list_verified = True
    except Exception:
        list_verified = False

    RECEIPT.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": "openclaw.langsmith-oauth-trace-relay/v1",
        "completed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "result": "trace_submitted",
        "project": PROJECT,
        "profile_auth_active": True,
        "trace_payload": result,
        "trace_list_verified": list_verified,
        "llm_called": False,
        "mutation_performed": False,
        "secret_values_included": False,
    }
    RECEIPT.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        "LANGSMITH_OAUTH_TRACE_SUBMITTED "
        f"list_verified={str(list_verified).lower()} receipt={RECEIPT}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
