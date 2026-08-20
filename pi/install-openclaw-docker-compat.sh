#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

AGENT_URL='https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/a71db8946d4658f90b28c3fd51e67dc98f6b54a2/pi/openclaw-docker-compat-agent.py'
AGENT_SHA256='fab29d2a9ec3417b881b4e9735afac0e78f03d74d09f5310301d08ec7db76188'
DOCKER_GPG_FINGERPRINT='9DC858229FC7DD38854AE2D88D81803C0EBFCD88'
ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
BIN_DIR="$HOME/.local/bin"
RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-$ROOT/runtime}"
ENV_FILE="${PI_WORK_QUEUE_ENV:-$ROOT/secrets/pi-work-queue.env}"
AGENT_PATH="$BIN_DIR/openclaw-docker-compat-agent"
INSTALL_RECEIPT="$RUNTIME_DIR/docker-compatibility-install-receipt.json"
AUTO_INSTALL_DOCKER="${AUTO_INSTALL_DOCKER:-1}"
TMP="$(mktemp -d)"
DOCKER_INSTALL_RESULT='not_needed'
TIMER_RESULT='not_installed'
AGENT_RESULT='not_run'

cleanup() {
  rm -rf -- "$TMP"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$RUNTIME_DIR" "$(dirname "$ENV_FILE")"
chmod 700 "$RUNTIME_DIR" "$(dirname "$ENV_FILE")"

for command in bash curl python3 sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'BLOCKED=missing_%s\n' "$command" >&2
    exit 40
  }
done

download_agent() {
  curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
    -o "$TMP/openclaw-docker-compat-agent.py" "$AGENT_URL"
  printf '%s  %s\n' "$AGENT_SHA256" "$TMP/openclaw-docker-compat-agent.py" |
    sha256sum -c -
  python3 -m py_compile "$TMP/openclaw-docker-compat-agent.py"
  install -m 0700 "$TMP/openclaw-docker-compat-agent.py" "$AGENT_PATH"
}

root_exec() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
  else
    return 77
  fi
}

docker_works() {
  if command -v docker >/dev/null 2>&1 &&
     docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
    return 0
  fi
  if command -v docker >/dev/null 2>&1 &&
     command -v sudo >/dev/null 2>&1 &&
     sudo -n docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

install_docker_official_repo() {
  [[ "$AUTO_INSTALL_DOCKER" == '1' ]] || return 78
  [[ -r /etc/os-release ]] || return 79
  # shellcheck disable=SC1091
  . /etc/os-release

  local arch repo_os key_url codename fingerprint
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$arch" in
    amd64|arm64) ;;
    *) return 80 ;;
  esac

  case "${ID:-}" in
    debian) repo_os='debian' ;;
    raspbian)
      # Raspberry Pi OS 64-bit follows Docker's Debian arm64 packages.
      [[ "$arch" == 'arm64' ]] || return 81
      repo_os='debian'
      ;;
    ubuntu) repo_os='ubuntu' ;;
    *) return 82 ;;
  esac

  codename="${VERSION_CODENAME:-}"
  [[ "$codename" =~ ^[a-z0-9._-]+$ ]] || return 83

  root_exec apt-get update || return $?
  root_exec apt-get install -y ca-certificates curl gnupg || return $?
  key_url="https://download.docker.com/linux/$repo_os/gpg"
  curl -fsSL --connect-timeout 15 --max-time 60 -o "$TMP/docker.asc" "$key_url"
  fingerprint="$(gpg --show-keys --with-colons "$TMP/docker.asc" |
    awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ "$fingerprint" == "$DOCKER_GPG_FINGERPRINT" ]] || return 84

  root_exec install -m 0755 -d /etc/apt/keyrings || return $?
  root_exec install -m 0644 "$TMP/docker.asc" /etc/apt/keyrings/docker.asc || return $?

  cat >"$TMP/docker.sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/$repo_os
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  root_exec install -m 0644 "$TMP/docker.sources" /etc/apt/sources.list.d/docker.sources || return $?
  root_exec apt-get update || return $?
  root_exec apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return $?
  root_exec systemctl enable --now docker || return $?
}

install_timer() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user show-environment >/dev/null 2>&1 || return 0
  mkdir -p "$HOME/.config/systemd/user"

  cat >"$HOME/.config/systemd/user/openclaw-docker-compat-preflight.service" <<EOF
[Unit]
Description=OpenClaw deterministic Docker compatibility preflight
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$AGENT_PATH preflight
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$ROOT
UMask=0077
TimeoutStartSec=15min
EOF

  cat >"$HOME/.config/systemd/user/openclaw-docker-compat-preflight.timer" <<'EOF'
[Unit]
Description=Periodically verify OpenClaw Docker compatibility

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
RandomizedDelaySec=5min
Persistent=true
Unit=openclaw-docker-compat-preflight.service

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now openclaw-docker-compat-preflight.timer
  TIMER_RESULT='active'
}

write_install_receipt() {
  python3 - "$INSTALL_RECEIPT" "$DOCKER_INSTALL_RESULT" "$TIMER_RESULT" "$AGENT_RESULT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    json.dumps(
        {
            "result": "installed",
            "docker_install_result": sys.argv[2],
            "preflight_timer": sys.argv[3],
            "agent_apply_result": sys.argv[4],
            "agent_sha256": "fab29d2a9ec3417b881b4e9735afac0e78f03d74d09f5310301d08ec7db76188",
            "agent_source_commit": "a71db8946d4658f90b28c3fd51e67dc98f6b54a2",
            "image": "docker.io/odifool/openclaw-compat:2026.08.20",
            "image_digest": "sha256:6c6df789c26cb0400171818fb0903d27ff799f9642d6e8c2eaf2b1c8e2e2894b",
            "docker_socket_mounted": False,
            "privileged_container": False,
            "provider_secret_exported": False,
            "docker_registry_secret_exported": False,
            "second_telegram_poller_created": False,
            "paid_api_fallback": False,
            "secret_values_included": False,
        },
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
path.chmod(0o600)
PY
}

download_agent

if docker_works; then
  DOCKER_INSTALL_RESULT='already_available'
elif command -v docker >/dev/null 2>&1; then
  if root_exec systemctl enable --now docker >/dev/null 2>&1 && docker_works; then
    DOCKER_INSTALL_RESULT='existing_daemon_restarted'
  else
    DOCKER_INSTALL_RESULT='existing_docker_daemon_unavailable'
  fi
elif install_docker_official_repo; then
  if docker_works; then
    DOCKER_INSTALL_RESULT='installed_official_repository'
  else
    DOCKER_INSTALL_RESULT='installed_but_daemon_unavailable'
  fi
else
  status="$?"
  DOCKER_INSTALL_RESULT="skipped_or_failed_code_$status"
fi

install_timer || TIMER_RESULT='degraded'

if "$AGENT_PATH" apply; then
  AGENT_RESULT='completed'
else
  AGENT_RESULT='blocked_or_degraded'
fi

write_install_receipt
printf 'RESULT=installed component=openclaw-docker-compat receipt=%s\n' "$INSTALL_RECEIPT"
