#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
UNIT_DIR="$CONFIG_HOME/systemd/user"
DROPIN_DIR="$UNIT_DIR/openclaw-gateway.service.d"
DROPIN="$DROPIN_DIR/90-external-macro-owner.conf"
BACKUP_ROOT="$ROOT/backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$BACKUP_ROOT/local-schedulers-$STAMP"
RECEIPT_DIR="$ROOT/receipts"
RECEIPT="$RECEIPT_DIR/local-schedulers-disabled.json"
LATEST_POINTER="$BACKUP_ROOT/local-schedulers-latest"
STATE_DB="$ROOT/state/openclaw.sqlite"

PRESERVED_TIMERS=(
  "openclaw-pi-recovery-worker-current.timer"
  "openclaw-pi-session-refresh.timer"
  "openclaw-telegram-delivery-worker.timer"
  "openclaw-external-scheduler-actuator.timer"
)

fail() {
  printf 'LOCAL_SCHEDULER_DISABLE_BLOCKED reason=%s\n' "$1" >&2
  exit "${2:-40}"
}

for command in python3 systemctl install mktemp grep awk; do
  command -v "$command" >/dev/null 2>&1 || fail "missing_$command"
done

mkdir -p "$BACKUP_ROOT" "$BACKUP" "$RECEIPT_DIR" "$DROPIN_DIR"
chmod 700 "$BACKUP_ROOT" "$BACKUP" "$RECEIPT_DIR" "$DROPIN_DIR"

# Idempotent success only when the prior receipt exists and the native Cron
# kill switch remains installed. This prevents a stale receipt from hiding a
# removed override.
if [[ -s "$RECEIPT" && -s "$DROPIN" ]] \
  && grep -Fqx 'Environment=OPENCLAW_SKIP_CRON=1' "$DROPIN" \
  && python3 - "$RECEIPT" <<'PY'
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
    and value.get("openclaw_native_cron_kill_switch") is True
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
systemctl --user is-active --quiet openclaw-gateway.service \
  && printf 'active\n' > "$BACKUP/gateway-state.before" \
  || printf 'inactive\n' > "$BACKUP/gateway-state.before"

# Preserve human-readable configuration and legacy Cron import artifacts.
for source in \
  "$ROOT/openclaw.json" \
  "$ROOT/cron/jobs.json" \
  "$ROOT/cron/jobs-state.json" \
  "$ROOT/cron/jobs-quarantine.json"
do
  if [[ -f "$source" ]]; then
    relative="${source#"$ROOT"/}"
    destination="$BACKUP/openclaw-files/$relative"
    mkdir -p "$(dirname "$destination")"
    cp -a -- "$source" "$destination"
  fi
done

# OpenClaw stores current automation state in SQLite. The kill switch does not
# mutate that database, but take a consistent backup when sqlite3 is available.
database_backup_mode="not_present"
if [[ -f "$STATE_DB" ]]; then
  if command -v sqlite3 >/dev/null 2>&1; then
    if sqlite3 "$STATE_DB" ".timeout 5000" ".backup '$BACKUP/openclaw.sqlite'" \
      >/dev/null 2>&1
    then
      database_backup_mode="sqlite_backup"
      chmod 600 "$BACKUP/openclaw.sqlite"
    else
      database_backup_mode="sqlite_backup_failed_nonblocking"
    fi
  else
    database_backup_mode="skipped_sqlite3_missing"
  fi
fi

python3 - "$BACKUP/crontab.before" "$BACKUP/crontab.after" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
project = re.compile(r"(openclaw|odi|n8n|langgraph|langchain|langsmith)", re.I)
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
kept = [line for line in lines if not project.search(line) or control.search(line)]
target.write_text("\n".join(kept) + ("\n" if kept else ""), encoding="utf-8")
PY

if command -v crontab >/dev/null 2>&1; then
  if [[ -s "$BACKUP/crontab.after" ]]; then
    crontab "$BACKUP/crontab.after"
  else
    crontab -r 2>/dev/null || true
  fi
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
  | grep -E '^(openclaw-|odi-|n8n-|langgraph-|langchain-|langsmith-).+\.timer$' \
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

# OpenClaw Cron runs inside the Gateway and current jobs are persisted in
# SQLite. Apply the official global scheduler kill switch rather than editing
# SQLite or deleting jobs, so rollback is immediate and lossless.
DROPIN_TMP="$(mktemp "$DROPIN_DIR/.90-external-macro-owner.XXXXXX")"
cat > "$DROPIN_TMP" <<'EOF_DROPIN'
[Service]
Environment=OPENCLAW_SKIP_CRON=1
EOF_DROPIN
install -m 0600 "$DROPIN_TMP" "$DROPIN"
rm -f "$DROPIN_TMP"

systemctl --user set-environment OPENCLAW_SKIP_CRON=1
systemctl --user daemon-reload

dropin_installed=false
manager_environment_set=false
gateway_restart_attempted=false
gateway_restart_succeeded=false
gateway_was_active=false

if [[ -s "$DROPIN" ]] && grep -Fqx 'Environment=OPENCLAW_SKIP_CRON=1' "$DROPIN"; then
  dropin_installed=true
fi
if systemctl --user show-environment 2>/dev/null \
  | grep -Fxq 'OPENCLAW_SKIP_CRON=1'
then
  manager_environment_set=true
fi
if [[ "$(cat "$BACKUP/gateway-state.before")" == "active" ]]; then
  gateway_was_active=true
  gateway_restart_attempted=true
  if systemctl --user try-restart openclaw-gateway.service; then
    gateway_restart_succeeded=true
  fi
fi

[[ "$dropin_installed" == true ]] || fail "openclaw_cron_dropin_not_installed"
[[ "$manager_environment_set" == true ]] || fail "openclaw_cron_manager_environment_not_set"
if [[ "$gateway_was_active" == true && "$gateway_restart_succeeded" != true ]]; then
  fail "openclaw_gateway_restart_failed"
fi

native_cron_status_exit_code=127
if command -v openclaw >/dev/null 2>&1; then
  set +e
  timeout 20s openclaw cron status \
    > "$BACKUP/openclaw-cron-status.after" 2>&1
  native_cron_status_exit_code=$?
  set -e
fi

printf '%s\n' "$BACKUP" > "$LATEST_POINTER"
chmod 600 "$LATEST_POINTER"

python3 - "$RECEIPT" "$BACKUP" \
  "$(printf '%s\n' "${disabled[@]}" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().splitlines() if x]))')" \
  "$(printf '%s\n' "${preserved[@]}" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().splitlines() if x]))')" \
  "$database_backup_mode" "$dropin_installed" "$manager_environment_set" \
  "$gateway_was_active" "$gateway_restart_attempted" "$gateway_restart_succeeded" \
  "$native_cron_status_exit_code" <<'PY'
import datetime
import json
import pathlib
import sys

receipt = pathlib.Path(sys.argv[1])
payload = {
    "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "result": "project_local_schedulers_disabled",
    "contract_version": 3,
    "scope": "project_schedulers_and_openclaw_native_cron",
    "backup_path": sys.argv[2],
    "disabled_user_timers": json.loads(sys.argv[3]),
    "preserved_control_timers": json.loads(sys.argv[4]),
    "database_backup_mode": sys.argv[5],
    "openclaw_native_cron_kill_switch": True,
    "openclaw_skip_cron_dropin_installed": sys.argv[6].lower() == "true",
    "openclaw_skip_cron_manager_environment_set": sys.argv[7].lower() == "true",
    "gateway_was_active": sys.argv[8].lower() == "true",
    "gateway_restart_attempted": sys.argv[9].lower() == "true",
    "gateway_restart_succeeded": sys.argv[10].lower() == "true",
    "native_cron_status_exit_code": int(sys.argv[11]),
    "job_definitions_deleted": False,
    "sqlite_modified": False,
    "preserved_services": [
        "openclaw-gateway.service",
        "tailscaled.service",
    ],
    "rollback_ready": True,
    "automatic_reboot": False,
    "unknown_process_kill": False,
    "secret_values_included": False,
}
receipt.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
receipt.chmod(0o600)
PY

printf 'LOCAL_SCHEDULERS_DISABLED native_cron=off receipt=%s backup=%s\n' \
  "$RECEIPT" "$BACKUP"
