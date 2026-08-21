#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_ROOT="$ROOT/backups"
BACKUP="$BACKUP_ROOT/local-schedulers-$STAMP"
RECEIPT_DIR="$ROOT/receipts"
RECEIPT="$RECEIPT_DIR/local-schedulers-disabled.json"
LATEST_POINTER="$BACKUP_ROOT/local-schedulers-latest"

PRESERVED_TIMERS=(
  "openclaw-pi-recovery-worker-current.timer"
  "openclaw-pi-session-refresh.timer"
  "openclaw-telegram-delivery-worker.timer"
  "openclaw-external-scheduler-actuator.timer"
)

mkdir -p "$BACKUP_ROOT" "$BACKUP" "$RECEIPT_DIR"
chmod 700 "$BACKUP_ROOT" "$BACKUP" "$RECEIPT_DIR"

if [[ -s "$RECEIPT" ]] && python3 - "$RECEIPT" <<'PY'
import json
import pathlib
import sys

try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
raise SystemExit(
    0
    if value.get("result") in {
        "project_local_schedulers_disabled",
        "project_local_schedulers_already_disabled",
    }
    else 1
)
PY
then
  printf 'LOCAL_SCHEDULERS_ALREADY_DISABLED receipt=%s\n' "$RECEIPT"
  exit 0
fi

crontab -l > "$BACKUP/crontab.before" 2>/dev/null || true
systemctl --user list-unit-files --type=timer --no-legend \
  > "$BACKUP/user-timer-unit-files.before" 2>/dev/null || true
systemctl --user list-units --type=timer --state=active --no-legend \
  | awk '{print $1}' \
  > "$BACKUP/user-timers-active.before" 2>/dev/null || true

python3 - "$BACKUP/crontab.before" "$BACKUP/crontab.after" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
project = re.compile(r"(openclaw|odi|n8n|langgraph)", re.I)
control = re.compile(
    r"(openclaw-pi-recovery-worker|openclaw-pi-session-refresh|"
    r"openclaw-telegram-delivery-worker|openclaw-external-scheduler-actuator|"
    r"openclaw-gateway|tailscale)",
    re.I,
)
lines = (
    source.read_text(encoding="utf-8", errors="replace").splitlines()
    if source.exists()
    else []
)
kept = [
    line
    for line in lines
    if not project.search(line) or control.search(line)
]
target.write_text(
    "\n".join(kept) + ("\n" if kept else ""),
    encoding="utf-8",
)
PY

if [[ -s "$BACKUP/crontab.after" ]]; then
  crontab "$BACKUP/crontab.after"
else
  crontab -r 2>/dev/null || true
fi

is_preserved() {
  local candidate="$1"
  local preserved
  for preserved in "${PRESERVED_TIMERS[@]}"; do
    [[ "$candidate" == "$preserved" ]] && return 0
  done
  return 1
}

mapfile -t timers < <(
  systemctl --user list-unit-files --type=timer --no-legend 2>/dev/null \
  | awk '{print $1}' \
  | grep -E '^(openclaw-|odi-|n8n-|langgraph-).+\.timer$' \
  || true
)

disabled=()
preserved=()
for timer in "${timers[@]}"; do
  if is_preserved "$timer"; then
    preserved+=("$timer")
    continue
  fi
  systemctl --user disable --now "$timer" >/dev/null 2>&1 || true
  disabled+=("$timer")
done

printf '%s\n' "$BACKUP" > "$LATEST_POINTER"
chmod 600 "$LATEST_POINTER"

python3 - "$RECEIPT" "$BACKUP" \
  "$(printf '%s\n' "${disabled[@]}" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().splitlines() if x]))')" \
  "$(printf '%s\n' "${preserved[@]}" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().splitlines() if x]))')" <<'PY'
import datetime
import json
import pathlib
import sys

receipt = pathlib.Path(sys.argv[1])
backup = sys.argv[2]
disabled = json.loads(sys.argv[3])
preserved = json.loads(sys.argv[4])
payload = {
    "completed_at": datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat(),
    "result": "project_local_schedulers_disabled",
    "scope": "project_schedulers_only",
    "backup_path": backup,
    "disabled_user_timers": disabled,
    "preserved_control_timers": preserved,
    "preserved_services": [
        "openclaw-gateway.service",
        "tailscaled.service",
    ],
    "rollback_ready": True,
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

printf 'LOCAL_SCHEDULERS_DISABLED receipt=%s backup=%s\n' \
  "$RECEIPT" "$BACKUP"
