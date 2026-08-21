#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DROPIN="$CONFIG_HOME/systemd/user/openclaw-gateway.service.d/90-external-macro-owner.conf"
DROPIN_DIR="$(dirname "$DROPIN")"
BACKUP_ROOT="$ROOT/backups"
LATEST_POINTER="$BACKUP_ROOT/local-schedulers-latest"
RECEIPT_DIR="$ROOT/receipts"
RECEIPT="$RECEIPT_DIR/local-schedulers-restored.json"

LATEST=""
if [[ -s "$LATEST_POINTER" ]]; then
  LATEST="$(cat "$LATEST_POINTER")"
fi
if [[ -z "$LATEST" || ! -d "$LATEST" ]]; then
  LATEST="$(
    find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'local-schedulers-*' \
      -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk 'NR==1 {print $2}'
  )"
fi
if [[ -z "$LATEST" || ! -d "$LATEST" ]]; then
  echo "LOCAL_SCHEDULER_ROLLBACK_BLOCKED reason=backup_not_found"
  exit 40
fi

if command -v crontab >/dev/null 2>&1 && [[ -f "$LATEST/crontab.before" ]]; then
  if [[ -s "$LATEST/crontab.before" ]]; then
    crontab "$LATEST/crontab.before"
  else
    crontab -r 2>/dev/null || true
  fi
fi

enabled=()
started=()
if [[ -f "$LATEST/user-timer-unit-files.before" ]]; then
  while read -r timer state _; do
    [[ "$timer" =~ ^(openclaw-|odi-|n8n-|langgraph-|langchain-|langsmith-).+\.timer$ ]] \
      || continue
    if [[ "$state" =~ ^enabled ]]; then
      systemctl --user enable "$timer" >/dev/null 2>&1 || true
      enabled+=("$timer")
    fi
  done < "$LATEST/user-timer-unit-files.before"
fi

if [[ -f "$LATEST/user-timers-active.before" ]]; then
  while read -r timer; do
    [[ "$timer" =~ ^(openclaw-|odi-|n8n-|langgraph-|langchain-|langsmith-).+\.timer$ ]] \
      || continue
    systemctl --user start "$timer" >/dev/null 2>&1 || true
    started+=("$timer")
  done < "$LATEST/user-timers-active.before"
fi

# Job definitions were never deleted or edited. Removing the Gateway drop-in
# re-enables the persisted OpenClaw SQLite scheduler losslessly.
rm -f -- "$DROPIN"
rmdir "$DROPIN_DIR" 2>/dev/null || true
systemctl --user unset-environment OPENCLAW_SKIP_CRON || true
systemctl --user daemon-reload

gateway_restart_attempted=false
gateway_restart_succeeded=false
gateway_started=false
if systemctl --user is-active --quiet openclaw-gateway.service; then
  gateway_restart_attempted=true
  if systemctl --user try-restart openclaw-gateway.service; then
    gateway_restart_succeeded=true
  fi
elif [[ -f "$LATEST/gateway-state.before" ]] \
  && [[ "$(cat "$LATEST/gateway-state.before")" == "active" ]]
then
  gateway_restart_attempted=true
  if systemctl --user start openclaw-gateway.service; then
    gateway_restart_succeeded=true
    gateway_started=true
  fi
fi

if [[ -e "$DROPIN" ]]; then
  echo "LOCAL_SCHEDULER_ROLLBACK_BLOCKED reason=cron_kill_switch_dropin_remains"
  exit 41
fi
if systemctl --user show-environment 2>/dev/null \
  | grep -Fxq 'OPENCLAW_SKIP_CRON=1'
then
  echo "LOCAL_SCHEDULER_ROLLBACK_BLOCKED reason=cron_kill_switch_environment_remains"
  exit 42
fi
if [[ "$gateway_restart_attempted" == true && "$gateway_restart_succeeded" != true ]]; then
  echo "LOCAL_SCHEDULER_ROLLBACK_BLOCKED reason=gateway_restart_failed"
  exit 43
fi

mkdir -p "$RECEIPT_DIR"
chmod 700 "$RECEIPT_DIR"

python3 - "$RECEIPT" "$LATEST" \
  "$(printf '%s\n' "${enabled[@]}" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().splitlines() if x]))')" \
  "$(printf '%s\n' "${started[@]}" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().splitlines() if x]))')" \
  "$gateway_restart_attempted" "$gateway_restart_succeeded" "$gateway_started" <<'PY'
import datetime
import json
import pathlib
import sys

receipt = pathlib.Path(sys.argv[1])
payload = {
    "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "result": "project_local_schedulers_restored",
    "contract_version": 3,
    "backup_path": sys.argv[2],
    "enabled_user_timers": json.loads(sys.argv[3]),
    "started_user_timers": json.loads(sys.argv[4]),
    "openclaw_native_cron_kill_switch_removed": True,
    "job_definitions_restored_in_place": True,
    "gateway_restart_attempted": sys.argv[5].lower() == "true",
    "gateway_restart_succeeded": sys.argv[6].lower() == "true",
    "gateway_started": sys.argv[7].lower() == "true",
    "automatic_reboot": False,
    "unknown_process_kill": False,
    "secret_values_included": False,
}
receipt.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
receipt.chmod(0o600)
PY

printf 'LOCAL_SCHEDULERS_RESTORED native_cron=on receipt=%s backup=%s\n' \
  "$RECEIPT" "$LATEST"
