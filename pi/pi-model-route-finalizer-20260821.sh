#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-$ROOT/runtime}"
RECEIPT="$RUNTIME_DIR/pi-model-route-finalizer-receipt.json"
LOCK_DIR="$RUNTIME_DIR/.pi-model-route-finalizer.lock"
CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-$ROOT/openclaw.json}"
TARGET_PRIMARY="supabase-opencode/nemotron-3-ultra-free"
TARGET_FALLBACK="supabase-opencode/laguna-s-2.1-free"
STALE_MODEL="openrouter/nvidia/nemotron-3-ultra-550b-a55b:free"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="${CONFIG_FILE}.before-model-route-finalizer-${STAMP}"

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  printf 'RESULT=already_running receipt=%s\n' "$RECEIPT"
  exit 0
fi
cleanup() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT

for command in openclaw python3 systemctl cp chmod; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'RESULT=blocked blocker=missing_%s\n' "$command" >&2
    exit 40
  }
done

if [[ -f "$CONFIG_FILE" ]]; then
  cp -p "$CONFIG_FILE" "$BACKUP"
  chmod 600 "$BACKUP" 2>/dev/null || true
else
  BACKUP=""
fi

read_model() {
  local raw
  raw="$(openclaw config get agents.defaults.model --json 2>/dev/null || true)"
  python3 - "$raw" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    value = json.loads(raw)
except Exception:
    print("\t")
    raise SystemExit(0)
if isinstance(value, str):
    print(value + "\t")
elif isinstance(value, dict):
    primary = value.get("primary") if isinstance(value.get("primary"), str) else ""
    fallbacks = value.get("fallbacks") if isinstance(value.get("fallbacks"), list) else []
    fallbacks = ",".join(item for item in fallbacks if isinstance(item, str))
    print(primary + "\t" + fallbacks)
else:
    print("\t")
PY
}

IFS=$'\t' read -r BEFORE_PRIMARY BEFORE_FALLBACKS < <(read_model)

PATCHED=false
if [[ "$BEFORE_PRIMARY" != "$TARGET_PRIMARY" || "$BEFORE_FALLBACKS" != "$TARGET_FALLBACK" ]]; then
  openclaw config set agents.defaults.models \
    '{"supabase-opencode/nemotron-3-ultra-free":{},"supabase-opencode/laguna-s-2.1-free":{}}' \
    --strict-json --merge

  openclaw config set agents.defaults.model \
    '{"primary":"supabase-opencode/nemotron-3-ultra-free","fallbacks":["supabase-opencode/laguna-s-2.1-free"]}' \
    --strict-json

  AGENT_MODEL="$(
    openclaw config get 'agents.entries.telegram-frontdoor.model' --json 2>/dev/null || true
  )"
  if printf '%s' "$AGENT_MODEL" | grep -Fq "$STALE_MODEL"; then
    openclaw config set 'agents.entries.telegram-frontdoor.model' \
      '{"primary":"supabase-opencode/nemotron-3-ultra-free","fallbacks":["supabase-opencode/laguna-s-2.1-free"]}' \
      --strict-json
  fi
  PATCHED=true
fi

openclaw config validate >/dev/null

IFS=$'\t' read -r AFTER_PRIMARY AFTER_FALLBACKS < <(read_model)
if [[ "$AFTER_PRIMARY" != "$TARGET_PRIMARY" || "$AFTER_FALLBACKS" != "$TARGET_FALLBACK" ]]; then
  if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
    cp -p "$BACKUP" "$CONFIG_FILE"
    openclaw config validate >/dev/null 2>&1 || true
  fi
  printf 'RESULT=blocked blocker=model_config_not_persisted primary=%s fallbacks=%s\n' \
    "$AFTER_PRIMARY" "$AFTER_FALLBACKS" >&2
  exit 41
fi

CATALOG_PRIMARY=false
CATALOG_FALLBACK=false
MODEL_LIST="$(openclaw models list --provider supabase-opencode 2>/dev/null || true)"
printf '%s\n' "$MODEL_LIST" | grep -Fq 'nemotron-3-ultra-free' && CATALOG_PRIMARY=true
printf '%s\n' "$MODEL_LIST" | grep -Fq 'laguna-s-2.1-free' && CATALOG_FALLBACK=true

systemctl --user daemon-reload

declare -a TIMERS=(
  "openclaw-pi-session-refresh.timer"
  "openclaw-pi-recovery-worker-current.timer"
  "openclaw-telegram-delivery-worker.timer"
)
declare -a SERVICES=(
  "openclaw-pi-session-refresh.service"
  "openclaw-pi-recovery-worker-current.service"
  "openclaw-telegram-delivery-worker.service"
)

timer_json="{"
first=true
for unit in "${TIMERS[@]}"; do
  state="not_installed"
  if systemctl --user list-unit-files "$unit" --no-legend 2>/dev/null | grep -Fq "$unit"; then
    if systemctl --user enable --now "$unit" >/dev/null 2>&1; then
      state="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
      [[ "$state" == "active" || "$state" == "waiting" ]] || state="enabled_degraded"
    else
      state="enable_failed"
    fi
  fi
  $first || timer_json+=","
  first=false
  timer_json+="\"$unit\":\"$state\""
done
timer_json+="}"

for unit in "${SERVICES[@]}"; do
  if systemctl --user list-unit-files "$unit" --no-legend 2>/dev/null | grep -Fq "$unit"; then
    systemctl --user start "$unit" >/dev/null 2>&1 || true
  fi
done

if [[ "$PATCHED" == "true" ]]; then
  openclaw gateway restart --safe >/dev/null 2>&1 \
    || systemctl --user restart openclaw-gateway.service
else
  systemctl --user is-active --quiet openclaw-gateway.service \
    || systemctl --user restart openclaw-gateway.service
fi

sleep 10

GATEWAY_STATE="$(systemctl --user is-active openclaw-gateway.service 2>/dev/null || true)"
RPC_OK=false
if openclaw gateway status --require-rpc >/dev/null 2>&1; then
  RPC_OK=true
fi

WORKER_RECEIPT="$RUNTIME_DIR/openclaw-recovery-worker-receipt.json"
MASTER_RECEIPT="$RUNTIME_DIR/pi-openclaw-master-recovery-receipt.json"
DELIVERY_RECEIPT="$RUNTIME_DIR/pi-telegram-delivery-worker-bootstrap-receipt.json"

python3 - "$RECEIPT" "$STAMP" "$BEFORE_PRIMARY" "$BEFORE_FALLBACKS" \
  "$AFTER_PRIMARY" "$AFTER_FALLBACKS" "$PATCHED" "$GATEWAY_STATE" "$RPC_OK" \
  "$CATALOG_PRIMARY" "$CATALOG_FALLBACK" "$timer_json" "$BACKUP" \
  "$MASTER_RECEIPT" "$WORKER_RECEIPT" "$DELIVERY_RECEIPT" <<'PY'
import json, pathlib, sys
(
    path, stamp, before_primary, before_fallbacks, after_primary, after_fallbacks,
    patched, gateway_state, rpc_ok, catalog_primary, catalog_fallback,
    timer_json, backup, master_receipt, worker_receipt, delivery_receipt
) = sys.argv[1:]
payload = {
    "receipt_type": "pi_model_route_finalizer",
    "completed_at": stamp,
    "before": {
        "primary": before_primary,
        "fallbacks": [x for x in before_fallbacks.split(",") if x],
    },
    "after": {
        "primary": after_primary,
        "fallbacks": [x for x in after_fallbacks.split(",") if x],
    },
    "config_patched": patched == "true",
    "catalog_primary_present": catalog_primary == "true",
    "catalog_fallback_present": catalog_fallback == "true",
    "gateway_state": gateway_state,
    "gateway_rpc_ok": rpc_ok == "true",
    "timers": json.loads(timer_json),
    "backup_path": backup or None,
    "master_receipt_present": pathlib.Path(master_receipt).is_file(),
    "worker_receipt_present": pathlib.Path(worker_receipt).is_file(),
    "delivery_receipt_present": pathlib.Path(delivery_receipt).is_file(),
    "paid_api_fallback": False,
    "second_telegram_poller_created": False,
    "unknown_process_killed": False,
    "automatic_reboot": False,
    "secret_values_included": False,
}
path_obj = pathlib.Path(path)
path_obj.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
path_obj.chmod(0o600)
PY

RESULT="ready"
[[ "$GATEWAY_STATE" == "active" && "$RPC_OK" == "true" ]] || RESULT="partial"

printf 'MODEL_ROUTE_RESULT result=%s primary=%s fallback=%s gateway=%s rpc=%s receipt=%s\n' \
  "$RESULT" "$AFTER_PRIMARY" "$AFTER_FALLBACKS" "$GATEWAY_STATE" "$RPC_OK" "$RECEIPT"
