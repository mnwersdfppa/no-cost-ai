#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
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

if [[ -f "$LATEST/crontab.before" ]]; then
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
    [[ "$timer" =~ ^(openclaw-|odi-|n8n-|langgraph-).+\.timer$ ]] \
      || continue
    if [[ "$state" =~ ^enabled ]]; then
      systemctl --user enable "$timer" >/dev/null 2>&1 || true
      enabled+=("$timer")
    fi
  done < "$LATEST/user-timer-unit-files.before"
fi

if [[ -f "$LATEST/user-timers-active.before" ]]; then
  while read -r timer; do
    [[ "$timer" =~ ^(openclaw-|odi-|n8n-|langgraph-).+\.timer$ ]] \
      || continue
    systemctl --user start "$timer" >/dev/null 2>&1 || true
    started+=("$timer")
  done < "$LATEST/user-timers-active.before"
fi

mkdir -p "$RECEIPT_DIR"
chmod 700 "$RECEIPT_DIR"

python3 - "$RECEIPT" "$LATEST" \
  "$(printf '%s\n' "${enabled[@]}" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().splitlines() if x]))')" \
  "$(printf '%s\n' "${started[@]}" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().splitlines() if x]))')" <<'PY'
import datetime
import json
import pathlib
import sys

receipt = pathlib.Path(sys.argv[1])
payload = {
    "completed_at": datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat(),
    "result": "project_local_schedulers_restored",
    "backup_path": sys.argv[2],
    "enabled_user_timers": json.loads(sys.argv[3]),
    "started_user_timers": json.loads(sys.argv[4]),
    "automatic_reboot": False,
    "unknown_process_kill": False,
    "secret_values_included": False,
}
receipt.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
receipt.chmod(0o600)
PY

printf 'LOCAL_SCHEDULERS_RESTORED receipt=%s backup=%s\n' \
  "$RECEIPT" "$LATEST"
