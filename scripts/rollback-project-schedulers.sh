#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
LATEST="$(
  find "$ROOT/backups" -maxdepth 1 -type d -name 'local-schedulers-*' \
    -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr \
  | awk 'NR==1 {print $2}'
)"

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

if [[ -f "$LATEST/user-timers.before" ]]; then
  awk '$1 ~ /^(openclaw-|odi-).+\.timer$/ && $2 ~ /^enabled/ {print $1}' \
    "$LATEST/user-timers.before" \
  | while read -r timer; do
      systemctl --user enable --now "$timer" >/dev/null 2>&1 || true
    done
fi

printf 'LOCAL_SCHEDULERS_RESTORED backup=%s\n' "$LATEST"
