#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

EXPECTED_SHA256="a9b179f18596aacf2b474ea2ce6ea3f6ec32335b65a1d3a3ab556ffa7d446d8a"
SCRIPT="/opt/test/pi-model-route-finalizer-20260821.sh"
OUT_DIR="/out"
ARCH="$(uname -m)"
HOME_DIR="$HOME"
CONFIG="$HOME_DIR/.openclaw/openclaw.json"
RUNTIME="$HOME_DIR/.openclaw/runtime"
RECEIPT="$RUNTIME/pi-model-route-finalizer-receipt.json"
STALE="openrouter/nvidia/nemotron-3-ultra-550b-a55b:free"
TARGET_PRIMARY="supabase-opencode/nemotron-3-ultra-free"
TARGET_FALLBACK="supabase-opencode/laguna-s-2.1-free"

mkdir -p "$RUNTIME" "$OUT_DIR"
chmod 700 "$HOME_DIR/.openclaw" "$RUNTIME"

ACTUAL_SHA256="$(sha256sum "$SCRIPT" | awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]]
bash -n "$SCRIPT"

python3 - "$CONFIG" "$STALE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
stale = sys.argv[2]
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(
    json.dumps(
        {
            "agents": {
                "defaults": {
                    "model": {"primary": stale, "fallbacks": [stale]},
                    "models": {stale: {}},
                },
                "entries": {
                    "telegram-frontdoor": {
                        "model": {"primary": stale, "fallbacks": []}
                    }
                },
            }
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
path.chmod(0o600)
PY

for file in \
  "$RUNTIME/pi-openclaw-master-recovery-receipt.json" \
  "$RUNTIME/openclaw-recovery-worker-receipt.json" \
  "$RUNTIME/pi-telegram-delivery-worker-bootstrap-receipt.json"; do
  printf '{"result":"mock-present","secret_values_included":false}\n' >"$file"
  chmod 600 "$file"
done

FIRST_OUTPUT="$(bash "$SCRIPT")"
printf '%s\n' "$FIRST_OUTPUT"
printf '%s\n' "$FIRST_OUTPUT" | grep -Fq 'MODEL_ROUTE_RESULT result=ready'

python3 - "$CONFIG" "$RECEIPT" "$TARGET_PRIMARY" "$TARGET_FALLBACK" <<'PY'
import json
import pathlib
import sys

config_path, receipt_path, primary, fallback = sys.argv[1:]
config = json.loads(pathlib.Path(config_path).read_text(encoding="utf-8"))
receipt = json.loads(pathlib.Path(receipt_path).read_text(encoding="utf-8"))

assert config["agents"]["defaults"]["model"] == {
    "primary": primary,
    "fallbacks": [fallback],
}
assert config["agents"]["entries"]["telegram-frontdoor"]["model"] == {
    "primary": primary,
    "fallbacks": [fallback],
}
assert receipt["after"]["primary"] == primary
assert receipt["after"]["fallbacks"] == [fallback]
assert receipt["config_patched"] is True
assert receipt["gateway_state"] == "active"
assert receipt["gateway_rpc_ok"] is True
assert receipt["catalog_primary_present"] is True
assert receipt["catalog_fallback_present"] is True
assert receipt["master_receipt_present"] is True
assert receipt["worker_receipt_present"] is True
assert receipt["delivery_receipt_present"] is True
assert receipt["paid_api_fallback"] is False
assert receipt["second_telegram_poller_created"] is False
assert receipt["secret_values_included"] is False
for value in receipt["timers"].values():
    assert value in {"active", "waiting"}
PY

SECOND_OUTPUT="$(bash "$SCRIPT")"
printf '%s\n' "$SECOND_OUTPUT"
printf '%s\n' "$SECOND_OUTPUT" | grep -Fq 'MODEL_ROUTE_RESULT result=ready'

python3 - "$RECEIPT" "$OUT_DIR/docker-validation-${ARCH}.json" "$ARCH" "$ACTUAL_SHA256" <<'PY'
import json
import pathlib
import sys

receipt_path, output_path, architecture, script_sha256 = sys.argv[1:]
receipt = json.loads(pathlib.Path(receipt_path).read_text(encoding="utf-8"))
assert receipt["config_patched"] is False
assert receipt["gateway_state"] == "active"
assert receipt["gateway_rpc_ok"] is True

summary = {
    "result": "pass",
    "architecture": architecture,
    "script_sha256": script_sha256,
    "primary": receipt["after"]["primary"],
    "fallbacks": receipt["after"]["fallbacks"],
    "gateway_state": receipt["gateway_state"],
    "gateway_rpc_ok": receipt["gateway_rpc_ok"],
    "idempotent_second_run": True,
    "paid_api_fallback": False,
    "second_telegram_poller_created": False,
    "network_used_during_runtime": False,
    "secret_values_included": False,
}
path = pathlib.Path(output_path)
path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
path.chmod(0o644)
print(json.dumps(summary, sort_keys=True))
PY

printf 'DOCKER_RECONCILE_PASS architecture=%s sha256=%s\n' "$ARCH" "$ACTUAL_SHA256"
