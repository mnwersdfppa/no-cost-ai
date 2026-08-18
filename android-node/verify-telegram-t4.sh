#!/usr/bin/env bash
set -euo pipefail

ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
LOGS="$ROOT/logs"
WAIT_SECONDS="${T4_WAIT_SECONDS:-240}"
mkdir -p "$LOGS"
chmod 700 "$ROOT" "$LOGS" 2>/dev/null || true

command -v openclaw >/dev/null 2>&1 || { echo 'BLOCKED=OPENCLAW_NOT_FOUND' >&2; exit 20; }
command -v journalctl >/dev/null 2>&1 || { echo 'BLOCKED=JOURNALCTL_NOT_FOUND' >&2; exit 21; }

CORRELATION="T4-$(date -u +%Y%m%dT%H%M%SZ)-$(python3 - <<'PY'
import secrets; print(secrets.token_hex(3).upper())
PY
)"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECEIPT="$LOGS/telegram-t4-$CORRELATION.json"

openclaw gateway status >/dev/null
openclaw status > "$LOGS/t4-status-$CORRELATION.txt" 2>&1 || true

POLLERS="$(pgrep -af 'openclaw.*(telegram|gateway)|telegram.*(poll|getUpdates)' || true)"
POLL_COUNT="$(printf '%s\n' "$POLLERS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"

printf '%s\n' \
  "CORRELATION_ID=$CORRELATION" \
  'SEND_TO_EXISTING_BOT:' \
  "$CORRELATION Reply exactly $CORRELATION and nothing else." \
  "WAIT_SECONDS=$WAIT_SECONDS"

FOUND=0
DEADLINE=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < DEADLINE )); do
  if journalctl --user -u openclaw-gateway --since "$START" --no-pager 2>/dev/null | grep -Fq "$CORRELATION"; then
    FOUND=1
    break
  fi
  sleep 5
done

BACKEND=""
MODEL=""
if (( FOUND == 1 )); then
  WINDOW="$(journalctl --user -u openclaw-gateway --since "$START" --no-pager 2>/dev/null | grep -F -C 15 "$CORRELATION" | tail -n 80)"
  BACKEND="$(printf '%s\n' "$WINDOW" | sed -nE 's/.*(provider|backend)[=: ]+([^ ,}]+).*/\2/ip' | tail -n1)"
  MODEL="$(printf '%s\n' "$WINDOW" | sed -nE 's/.*model[=: ]+([^ ,}]+).*/\1/ip' | tail -n1)"
fi

python3 - "$RECEIPT" "$CORRELATION" "$START" "$FOUND" "$POLL_COUNT" "$BACKEND" "$MODEL" <<'PY'
import datetime,json,os,sys
path,corr,start,found,poll_count,backend,model=sys.argv[1:]
payload={
  'result':'pass' if found=='1' else 'not_observed',
  'correlation_id':corr,
  'started_at':start,
  'completed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
  'existing_bot_roundtrip_observed':found=='1',
  'process_match_count':int(poll_count),
  'backend':backend or None,
  'model':model or None,
  'new_telegram_poller_created':False,
  'secret_values_exposed':False
}
with open(path,'w',encoding='utf-8') as f: json.dump(payload,f,ensure_ascii=False,indent=2)
os.chmod(path,0o600)
PY

if (( FOUND == 1 )); then
  echo 'RESULT=T4_ROUNDTRIP_OBSERVED'
  echo "RECEIPT=$RECEIPT"
  exit 0
fi

echo 'RESULT=T4_NOT_OBSERVED'
echo "RECEIPT=$RECEIPT"
echo 'NEXT=check the existing Telegram connector and gateway logs; do not create another bot poller'
exit 22
