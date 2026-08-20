---
name: runtime-compatibility-resolver
description: Resolve operating-system, architecture, package and runtime mismatches with verified native paths, multiarchitecture Docker images or bounded host adapters.
---

# Runtime Compatibility Resolver

## Selection order

1. Use a verified native path when the operating system and architecture are supported.
2. Use a pinned multiarchitecture container for portable validation and user-space tooling.
3. Use a fixed native host adapter when systemd, hardware, networking, Tailscale, Ollama acceleration or OpenClaw Gateway control is required.
4. Block the operation when no verified profile exists.

## Docker defaults

- immutable image digest
- `linux/arm64` and `linux/amd64` manifests when applicable
- non-root user
- read-only root filesystem
- `--cap-drop=ALL`
- `no-new-privileges`
- no Docker socket
- no host PID namespace
- no host network by default
- read-only workspace mount
- bounded memory, CPU and PID limits
- no embedded credentials

Canonical portable image:

```text
docker.io/odifool/openclaw-compat:2026.08.20
sha256:6c6df789c26cb0400171818fb0903d27ff799f9642d6e8c2eaf2b1c8e2e2894b
```

## Native-only responsibilities

Keep these outside the portable container:

- systemd user-service control
- Tailscale daemon and node enrollment
- Ollama hardware acceleration
- OpenClaw Gateway restart and port ownership
- Telegram inbound polling
- host package installation

## Conflict policy

Preserve existing Docker, Podman or containerd installations. Do not uninstall, replace or reconfigure an unknown runtime automatically. Unknown conflicts fail closed and produce a diagnostic receipt.

## Receipt

Return detected OS and architecture, Docker availability, selected runtime, image digest or host adapter, decision reason, resource limits and `secret_values_included=false`.
