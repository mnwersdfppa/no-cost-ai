# OpenClaw Compute Fabric v2

## Goal
Keep the control plane always-on at low fixed cost, and attach expensive accelerators only when a workload justifies them.

## Always-on control plane
- Oracle A1 Docker: target primary OpenClaw runtime
- AWS existing cbdfh: immediate recovery / temporary fallback only
- Supabase: memory, SSOT, checkpoints
- n8n Community self-hosted: scheduler
- Cloudflare Workers: edge ingress / health routing
- Cloudflare R2: snapshots and backup
- Vercel: optional UI/API facade/cache, not the daemon
- Pi5: secondary edge/local worker

## Model routing
1. Local/open models first when quality is sufficient.
2. Paid frontier API models are on-demand tools, not fixed always-on subscriptions.
3. Measure quality, latency and cost per task before promotion.
4. Docker Model Runner is the serving/packaging layer, not a reason by itself to buy a model subscription.

## Accelerator tiers
- CPU/ARM: always-on orchestration, tools, memory, small models.
- GPU: on-demand for high-throughput inference, image/video, training/fine-tuning.
- TPU: on-demand for XLA/JAX-compatible training/inference workloads.
- QPU: research/benchmark adapter only. Never required for core OpenClaw availability.

## Mojo / MAX profile
- Enable a separate accelerator worker image based on Ubuntu 22.04+.
- Target x86_64 and ARM64 CPU first.
- GPU profiles may target NVIDIA/AMD where available.
- Do not put Mojo/MAX on the tiny recovery host if RAM is below the documented minimum.

## Stability and cost gates
- Preserve brain v13 and newer verified state.
- Never create a second Telegram poller.
- Keep expensive accelerators off when idle.
- Duplicate SaaS is downgraded only after 7 consecutive healthy days and rollback verification.
- Final subscription changes require user confirmation at execution time.

## Migration order
1. Recover OpenClaw conversation continuity on existing AWS cbdfh.
2. Move primary runtime to Oracle A1 Docker.
3. Move scheduling to self-hosted n8n Community.
4. Add Cloudflare edge and R2 backup.
5. Add Mojo/MAX accelerator-worker profile.
6. Add GPU/TPU burst adapters.
7. Add optional QPU research adapter.
8. Reduce duplicate SaaS after stability gates pass.
