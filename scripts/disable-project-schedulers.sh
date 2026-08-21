#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$ROOT/backups/local-schedulers-$STAMP"
RECEIPT="$ROOT/receipts/local-schedulers-disabled.json"

mkdir -p "$BACKUP" "$ROOT/receipts"
chmod 700 "$ROOT/backups" "$BACKUP" "$ROOT/receipts"

crontab -l > "$BACKUP/crontab.before" 2>/dev/null || true
systemctl --user list-unit-files --type=timer --no-legend \
  > "$BACKUP/user-timers.before" 2>/dev/null || true

python3 - "$BACKUP/crontab.before" "$BACKUP/crontab.after" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
pattern = re.compile(r"(openclaw|odi|n8n|langgraph)", re.I)
lines = source.read_text(encoding="utf-8", errors="replace").splitlines() if source.exists() else []
kept = [line for line in lines if not pattern.search(line)]
target.write_text("\n".join(kept) + ("\n" if kept else ""), encoding="utf-8")
PY

if [[ -s "$BACKUP/crontab.after" ]]; then
  crontab "$BACKUP/crontab.after"
else
  crontab -r 2>/dev/null || true
fi

mapfile -t timers < <(
  systemctl --user list-unit-files --type=timer --no-legend 2>/dev/null \
  | awk '{print $1}' \
  | grep -E '^(openclaw-|odi-).+\.timer$' \
  || true
)

disabled=()
for timer in "${timers[@]}"; do
  systemctl --user disable --now "$timer" >/dev/null 2>&1 || true
  disabled+=("$timer")
done

python3 - "$RECEIPT" "$BACKUP" "${disabled[@]}" <<'PY'
import datetime
import json
import pathlib
import sys

receipt = pathlib.Path(sys.argv[1])
backup = sys.argv[2]
disabled = sys.argv[3:]
payload = {
    "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "result": "project_local_schedulers_disabled",
    "scope": "project_schedulers_only",
    "backup_path": backup,
    "disabled_user_timers": disabled,
    "preserved_services": [
        "openclaw-gateway.service",
        "tailscaled.service",
    ],
    "automatic_reboot": False,
    "unknown_process_kill": False,
    "secret_values_included": False,
}
receipt.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
receipt.chmod(0o600)
PY

printf 'LOCAL_SCHEDULERS_DISABLED receipt=%s backup=%s\n' "$RECEIPT" "$BACKUP"
