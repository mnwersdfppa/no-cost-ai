#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FETCHER="$SCRIPT_DIR/fetch-canonical-client-config.sh"
UNIT_DIR="$HOME/.config/systemd/user"

command -v systemctl >/dev/null 2>&1 || {
  echo 'BLOCKED=SYSTEMD_USER_REQUIRED' >&2
  exit 20
}
[[ -r "$FETCHER" ]] || {
  echo "BLOCKED=FETCHER_MISSING:$FETCHER" >&2
  exit 21
}

mkdir -p "$UNIT_DIR"
chmod 700 "$FETCHER"

cat > "$UNIT_DIR/openclaw-canonical-config-refresh.service" <<EOF
[Unit]
Description=Refresh canonical Supabase/Vercel client configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$FETCHER
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$HOME/.openclaw
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
TimeoutStartSec=60
EOF

cat > "$UNIT_DIR/openclaw-canonical-config-refresh.timer" <<'EOF'
[Unit]
Description=Periodically refresh canonical client configuration

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
RandomizedDelaySec=5min
Persistent=true
Unit=openclaw-canonical-config-refresh.service

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now openclaw-canonical-config-refresh.timer

# Run once now. A missing/expired Pi JWT fails closed and preserves any previous
# canonical output file; the timer retries only after its normal interval.
if systemctl --user start openclaw-canonical-config-refresh.service; then
  echo 'INITIAL_REFRESH=PASS'
else
  echo 'INITIAL_REFRESH=BLOCKED_CHECK_JWT'
fi
systemctl --user status openclaw-canonical-config-refresh.timer --no-pager || true

echo 'RESULT=CANONICAL_CONFIG_REFRESH_TIMER_ENABLED'
