#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$BASE_DIR/docker-compose.recovery.yml"
STATE_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$STATE_DIR/workspace}"
AUTH_DIR="${OPENCLAW_AUTH_PROFILE_SECRET_DIR:-$HOME/.openclaw-auth-profile-secrets}"
IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"

log(){ printf '[openclaw-recovery] %s\n' "$*"; }
fail(){ printf '[openclaw-recovery] ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker_missing"
docker compose version >/dev/null 2>&1 || fail "docker_compose_v2_missing"

# Continuity guard: never create a blank assistant over the user's existing friend.
[[ -d "$STATE_DIR" ]] || fail "existing_openclaw_state_not_found:$STATE_DIR"
if [[ ! -f "$STATE_DIR/openclaw.json" && ! -d "$WORKSPACE_DIR" ]]; then
  fail "continuity_state_not_found_refusing_fresh_onboard"
fi

mkdir -p "$WORKSPACE_DIR" "$AUTH_DIR"
# Official container runs as uid 1000. Only fix paths we explicitly own.
if [[ "$(id -u)" -eq 0 ]]; then
  chown -R 1000:1000 "$STATE_DIR" "$WORKSPACE_DIR" || true
  chown -R 1000:1000 "$AUTH_DIR" || true
fi

export OPENCLAW_IMAGE="$IMAGE"
export OPENCLAW_CONFIG_DIR="$STATE_DIR"
export OPENCLAW_WORKSPACE_DIR="$WORKSPACE_DIR"
export OPENCLAW_AUTH_PROFILE_SECRET_DIR="$AUTH_DIR"
export OPENCLAW_TZ="${OPENCLAW_TZ:-Asia/Seoul}"

log "pulling_openclaw_image"
docker pull "$IMAGE" >/dev/null

log "stopping_only_recovery_stack"
docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true

log "starting_gateway"
docker compose -f "$COMPOSE_FILE" up -d openclaw-gateway

log "waiting_for_gateway_health"
healthy=0
for _ in $(seq 1 24); do
  cid="$(docker compose -f "$COMPOSE_FILE" ps -q openclaw-gateway)"
  [[ -n "$cid" ]] || { sleep 5; continue; }
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
  if [[ "$status" == "healthy" || "$status" == "running" ]]; then
    healthy=1
    break
  fi
  sleep 5
done
[[ "$healthy" -eq 1 ]] || { docker compose -f "$COMPOSE_FILE" logs --tail=80 openclaw-gateway >&2 || true; fail "gateway_not_healthy"; }

log "running_doctor"
docker compose -f "$COMPOSE_FILE" run -T --rm openclaw-cli doctor --json >/tmp/openclaw-doctor.json 2>/tmp/openclaw-doctor.err || true

# Telegram continuity: add/use env token only when present; never print it.
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  log "ensuring_telegram_channel"
  docker compose -f "$COMPOSE_FILE" run -T --rm openclaw-cli channels add --channel telegram --token "$TELEGRAM_BOT_TOKEN" >/tmp/openclaw-telegram-add.out 2>/tmp/openclaw-telegram-add.err || true
fi

log "probing_gateway"
if docker compose -f "$COMPOSE_FILE" run -T --rm openclaw-cli gateway probe >/tmp/openclaw-gateway-probe.out 2>/tmp/openclaw-gateway-probe.err; then
  log "OPENCLAW_DOCKER_RECOVERY_OK"
  exit 0
fi

docker compose -f "$COMPOSE_FILE" logs --tail=100 openclaw-gateway >&2 || true
fail "gateway_probe_failed"
