# OpenClaw Docker Compatibility System

Status: `CLOUD_READY_PHYSICAL_PI_PENDING`

## Purpose

Use a verified multi-platform container as a read-only compatibility and artifact-validation layer when host operating-system, CPU architecture, dependency, or artifact-size differences would otherwise block Raspberry Pi 5 OpenClaw recovery.

Docker is not used to hide host-kernel requirements. Tailscale TUN, systemd service control, USB/GPIO/GPU drivers, and the existing singleton Telegram poller remain host-native.

## Canonical artifact

- Image: `docker.io/odifool/openclaw-compat:2026.08.20`
- Immutable reference: `docker.io/odifool/openclaw-compat@sha256:6c6df789c26cb0400171818fb0903d27ff799f9642d6e8c2eaf2b1c8e2e2894b`
- Platforms: `linux/amd64`, `linux/arm64`
- Base: `docker.io/library/alpine:3.24.1`
- User: `65532:65532`
- Runtime default: read-only filesystem, network disabled, all capabilities dropped, no new privileges, 64 PID limit, 128 MiB memory limit
- Docker socket: not mounted
- Provider, Telegram, Tailscale, Supabase service-role and registry credentials: absent
- Telegram poller: absent

## Credential boundary

The Supabase Edge secret alias `Docker-api-key` contains English Docker login instructions and an embedded modern Docker Hub PAT. The server-side parser identified the login identifier and PAT without returning either value.

Validated server-side operations:

- Docker Hub authentication: HTTP 200
- public image pull scope: HTTP 200
- namespace pull scope: HTTP 200
- namespace push scope: HTTP 200

The PAT remains in Supabase Edge. Raspberry Pi runtime pull is anonymous because the image repository is public. GitHub publishing uses a brokered GitHub OIDC exchange for a short-lived repository-scoped registry token. Automatic publishing on branch push is disabled; publication requires explicit `workflow_dispatch` input.

## Decision order

1. `native_host_required`: required for Tailscale TUN, systemd, hardware devices, drivers and the existing Telegram singleton.
2. `docker_multiarch`: use the exact digest when a native `linux/amd64` or `linux/arm64` manifest exists.
3. `docker_qemu_explicit`: disabled by default and allowed only by a workload profile.
4. `supabase_edge`: preserve the request in the cloud queue when the Pi cannot safely execute it.
5. `blocked`: fail closed when no verified route exists.

Architecture normalization:

- `aarch64`, `arm64`, `arm64v8` → `arm64`
- `x86_64`, `x64`, `amd64` → `amd64`
- `armv7l`, `armhf` → `arm/v7`

## Canonical Pi entrypoint

`pi-container-bootstrap` v3 accepts a scoped `pi-gateway-client` access token or current-format refresh token, records the host fingerprint, and returns typed execution steps only. It never returns the Docker PAT or provider secrets.

Verified routes:

- Docker available + public pull available → immutable multiarch preflight, then SHA-verified native recovery
- Docker available + Buildx available + registry pull unavailable → local BuildKit preflight, then SHA-verified native recovery
- Docker unavailable → SHA-verified native recovery
- runtime disk below native minimum → Supabase Edge queue

Typed Docker execution uses argument arrays and `shell=false`. It never executes commands supplied by a queue payload.

## Generic profiles

- `openclaw.portable_validation.v1`
- `openclaw.host_control.v1`
- `openclaw.ffmpeg.v1`
- `openclaw.n8n.v1`
- `openclaw.supabase_edge_local.v1`
- `openclaw.tailscale.v1`
- `openclaw.telegram_poller.v1`

Each future component must declare:

- supported operating systems and architectures
- native-only kernel or singleton requirements
- minimum memory and disk
- Docker eligibility
- optional QEMU eligibility
- immutable image digest
- read-only, capability, network and secret-mount policy
- fallback order

## Completion boundary

Cloud publication, policy resolution and Pi bootstrap E2E have passed. Completion still requires the physical Raspberry Pi to execute the verified Docker/native installer and produce real OpenClaw, Docker, Tailscale and Telegram receipts. The Draft PR must not be merged before those receipts exist.
