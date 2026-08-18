#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${OPENCLAW_PHONE_ROOT:-$HOME/.openclaw/phone-bridge}"
SECRETS="${OPENCLAW_SECRETS_DIR:-$HOME/.openclaw/secrets}"
ENV_FILE="$SECRETS/phone-bridge.env"
BIN="$HOME/.openclaw/bin"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/openclaw-phone-relay.service"
POLICY_FILE="$ROOT/relay-policy.txt"

for cmd in node npm openclaw systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "BLOCKED=MISSING_COMMAND:$cmd"; exit 80; }
done
[[ -r "$ENV_FILE" ]] || { echo "BLOCKED=PHONE_BRIDGE_ENV_MISSING"; exit 81; }

mkdir -p "$ROOT" "$SECRETS" "$BIN" "$SERVICE_DIR"
chmod 700 "$ROOT" "$SECRETS" "$BIN" "$SERVICE_DIR"
rm -rf "$ROOT/channel-relay"
cp -a "$SCRIPT_DIR/channel-relay" "$ROOT/channel-relay"
(
  cd "$ROOT/channel-relay"
  npm install --omit=dev --ignore-scripts --no-audit --no-fund
  npm run check
)

for entry in \
  'PHONE_RELAY_ENABLED=0' \
  'PHONE_RELAY_ALLOW_COMMANDS=0' \
  'PHONE_RELAY_ALLOW_GROUPS=0' \
  'PHONE_RELAY_SESSION_REGEX=(telegram.*direct|direct.*telegram)' \
  'PHONE_RELAY_MAX_INPUT=12000' \
  'PHONE_RELAY_MAX_OUTPUT=20000'; do
  key="${entry%%=*}"
  grep -q "^${key}=" "$ENV_FILE" || printf '%s\n' "$entry" >> "$ENV_FILE"
done
chmod 600 "$ENV_FILE"

cat > "$POLICY_FILE" <<'POLICY'
Reply in the user's language.
Be concise, action-first, and honest about uncertainty.
Never expose API keys, OAuth tokens, passwords, private configuration, or authentication files.
Do not claim a device, Telegram, OpenClaw, GitHub, Supabase, or external action completed unless evidence proves it.
This relay produces text replies only. Do not pretend to execute phone or OpenClaw tools.
The Raspberry Pi OpenClaw Gateway remains the single Telegram poller and routing owner.
Prefer the user's established operating principles: low friction, reversible changes, verify before reporting, and one next action when blocked.
POLICY
chmod 600 "$POLICY_FILE"

cat > "$BIN/phone-channel-relay" <<LAUNCH
#!/usr/bin/env bash
set -euo pipefail
set -a
source "$ENV_FILE"
set +a
exec node "$ROOT/channel-relay/relay.mjs"
LAUNCH
chmod 700 "$BIN/phone-channel-relay"

cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=OpenClaw Telegram to attached-phone Codex relay
After=network-online.target openclaw-gateway.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN/phone-channel-relay
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$ROOT $SECRETS
RestrictSUIDSGID=true
LockPersonality=true
UMask=0077

[Install]
WantedBy=default.target
UNIT
chmod 600 "$SERVICE_FILE"
systemctl --user daemon-reload
systemctl --user disable --now openclaw-phone-relay.service >/dev/null 2>&1 || true

echo "RESULT=CHANNEL_RELAY_INSTALLED_DISABLED"
echo "ENABLE_AFTER_PHONE_VERIFY=$SCRIPT_DIR/enable-channel-relay.sh"
echo "POLICY=single Telegram poller; direct chats only; slash commands and groups denied by default"
