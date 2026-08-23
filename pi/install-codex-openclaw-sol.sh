#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi 5 / Linux ARM64 preparation for ChatGPT/Codex subscription OAuth in OpenClaw.
# This script intentionally does NOT embed API keys.
# It installs Codex CLI, repairs OpenClaw, configures GPT-5.6 Sol as primary,
# and leaves only the interactive ChatGPT device-code approval for the user.

log(){ printf '[setup] %s\n' "$*"; }
fail(){ printf '[setup][ERROR] %s\n' "$*" >&2; exit 1; }

ARCH="$(uname -m)"
OS="$(uname -s)"
[[ "$OS" == "Linux" ]] || fail "Linux required (got $OS)"
case "$ARCH" in aarch64|arm64) ;; *) log "warning: expected ARM64 Pi, got $ARCH" ;; esac

command -v curl >/dev/null || fail "curl is required"

log "1/8 Install or verify OpenAI Codex CLI"
if ! command -v codex >/dev/null 2>&1; then
  # Official installer supports Linux arm64.
  if ! curl -fsSL https://chatgpt.com/codex/install.sh | sh; then
    log "official installer failed; trying npm fallback"
    command -v npm >/dev/null || fail "npm missing and Codex installer failed"
    npm install -g @openai/codex
  fi
fi
codex --version || fail "Codex CLI install verification failed"

log "2/8 Install or verify OpenClaw"
if ! command -v openclaw >/dev/null 2>&1; then
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard
  export PATH="$HOME/.local/bin:$HOME/.openclaw/bin:$PATH"
fi
command -v openclaw >/dev/null || fail "OpenClaw not found after install"
openclaw --version || true

log "3/8 Repair legacy config/plugin routes"
openclaw doctor --fix || true
openclaw config validate || true

log "4/8 Set canonical subscription-backed GPT-5.6 Sol route"
# IMPORTANT: this is a shell command, not text to type inside the Codex chat prompt.
openclaw config set agents.defaults.model.primary openai/gpt-5.6-sol

log "5/8 Ensure gateway service exists"
openclaw gateway install --force || true

log "6/8 Check existing OpenAI OAuth profile"
if openclaw models auth list --provider openai --json > /tmp/openclaw-openai-auth.json 2>/dev/null; then
  if grep -q 'openai' /tmp/openclaw-openai-auth.json; then
    log "existing OpenAI auth profile detected"
  else
    log "no usable OpenAI auth profile detected"
  fi
else
  log "auth list unavailable; continuing to interactive login step"
fi

log "7/8 Interactive ChatGPT device-code login is the only expected manual step"
printf '\nRun this on the Pi terminal and approve it on the iPhone browser:\n\n'
printf '  openclaw models auth login --provider openai --device-code --set-default\n\n'
printf 'After approval, run:\n\n'
printf '  %s\n' "$HOME/.openclaw/bin/finish-sol 2>/dev/null || true

mkdir -p "$HOME/.openclaw/bin"
cat > "$HOME/.openclaw/bin/finish-sol" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
openclaw doctor --fix || true
openclaw config set agents.defaults.model.primary openai/gpt-5.6-sol
openclaw config validate
openclaw models list --provider openai
openclaw models status --probe --probe-provider openai || openclaw models status
openclaw gateway restart --safe || openclaw gateway restart
openclaw gateway status --deep || openclaw gateway status
printf '\nTelegram verification commands:\n  /codex status\n  /codex models\n\n'
printf 'Expected primary: openai/gpt-5.6-sol\n'
EOF
chmod 700 "$HOME/.openclaw/bin/finish-sol"

log "8/8 Preconfiguration complete"
log "primary=openai/gpt-5.6-sol"
log "manual_remaining=device-code OAuth approval, then ~/.openclaw/bin/finish-sol"
