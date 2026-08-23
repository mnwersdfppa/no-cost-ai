# Pattern–Macro–Algorithm 24×7 Operating Contract

**Recorded:** 2026-08-23  
**Runtime state:** `LIVE_IN_USE`  
**Primary mode:** event-driven, zero-cost hot path  
**Authoritative state:** Supabase  

## 1. Objective

Keep the OpenClaw system available for continuous work without turning “24×7” into unbounded polling, retries, model calls, or duplicated schedulers.

The operating hierarchy is:

`Signal → Pattern → Macro → Algorithm → State transition → Evidence`

- **Pattern**: a recurring situation shape that can be recognized again.
- **Macro**: a reusable, bounded sequence of actions with a fixed budget and stop condition.
- **Algorithm**: the higher-order policy that selects, sequences, admits, retries, pauses, verifies, and promotes macros.

“Always working” means the system is always ready to receive events and resume durable work. It does **not** mean every component polls continuously.

## 2. Required control patterns

| Layer | English term | Operational rule |
|---|---|---|
| Intake | Signal | Accept a bounded event or state change. |
| Recognition | Pattern | Fingerprint and group repeated situations. |
| Reuse | Macro | Execute a fixed action bundle instead of reasoning again. |
| Governance | Algorithm | Select the safest and cheapest eligible macro. |
| Load control | Backpressure | Coalesce or defer work before queues and providers overload. |
| Replay safety | Idempotency | One execution key maps to one execution and one receipt chain. |
| Failure isolation | Circuit breaker | Stop hammering an unhealthy provider and open a cooldown gate. |
| Concurrency | Work lease | Use short fenced claims so multiple workers cannot duplicate work. |
| Completion | Evidence | Require provider, database, CI, or artifact readback before success. |

## 3. Execution ladder

The engine must choose the first safe lane that can complete the task:

1. **Reuse an existing validated skill or macro.**
2. **Run a deterministic RPC, transformation, cache, or readback.**
3. **Publish one durable event to a bounded queue.**
4. **Lease the task to one capability-matched worker.**
5. **Hold for OAuth, physical access, external write, release, or cost approval.**

A model is not the default execution engine. It is a bounded specialist used only when deterministic execution cannot satisfy the contract.

## 4. Admission algorithm

```text
on event:
  validate bounded schema and reject secret-like input
  compute execution key and state fingerprint
  if the execution key already exists:
    return the original state and receipts

  classify exactly one primary MECE domain
  resolve the lowest-cost eligible macro and surface
  apply rate, queue, concurrency, cost, and authority limits

  if a required capability, identity, OAuth grant, or physical actor is absent:
    hold with one explicit blocker code
  else if deterministic inline execution is eligible:
    execute once and verify readback
  else:
    enqueue once, acquire a fenced lease, and run with bounded retries

  on repeated failure:
    open the circuit breaker and defer until cooldown
  on success:
    record immutable evidence and close the circuit
```

## 5. Surface ownership

| Surface | Role | Current operating rule |
|---|---|---|
| Supabase | Hot-path state, queues, leases, idempotency, algorithm plans, receipts | Active and authoritative. |
| OpenClaw | Event orchestration and worker control | Active; must not infer physical completion from cloud state. |
| n8n | Sole recurring scheduler | Quota-guarded. High-frequency OpenClaw fanout remains held; do not create a second scheduler. |
| GitHub | Source, review, exact-head CI, immutable code receipts | Event/PR driven; never use as a polling worker. |
| Linear | Work-status projection | Idempotent projection only; not execution SSOT. |
| Notion | Human-readable projection | Idempotent projection only; not execution SSOT. |
| Vercel | Stateless ingress and status surface | Short requests only; no durable loop ownership. |
| OpenCode | Scoped on-demand code worker | Ready in source; physical Windows health and exact-scope CI remain required for real code claims. |
| Tailscale | Private transport and event signal | Gated until a valid identity/signature boundary is verified. |
| Atlassian Teamwork Graph CLI | Permission-aware context graph | Gated by device-side OAuth and Atlassian permissions. |
| Webcmd | Learn-once browser macro compiler | Gated; begin with read-only canary evidence on the physical Windows browser session. |
| Semrush | Search/market research specialist | On-demand only; cache results and never place it in the hot path. |
| ButlerBrain | Cold-context pointer cache | Store compact pointers to canonical receipts, not a second execution history. |
| Qlynk Agent Builder | Offline agent build and evaluation | Use for bounded build packs/tests, not as the 24×7 scheduler. |

## 6. Verified live receipt

The following approved deterministic execution completed in Supabase:

- execution key: `chatgpt:2026-08-23:pattern-macro-algorithm-24x7-v1`
- algorithm: `event-contract-executor` v1
- MECE domain: `deterministic_control`
- run ID: `51241952-3b3e-4d0b-af91-59a4f675792b`
- event ID: `a4d9e638-fc88-46a8-b5c6-7b949cff520d`
- plan SHA-256: `e47786abbb15f731d0092667288c27026de44b398c2474993d6273857316937a`
- state: `completed`
- blocker: none
- queue backend: none
- model called: false
- polling required: false
- new recurring path created: false
- second Telegram poller created: false
- raw text stored: false
- secret values included: false

A replay with the same execution key returned `duplicate=true` and reused the original run and evidence instead of creating another execution.

## 7. Non-negotiable invariants

- No new recurring scheduler while n8n is the sole scheduler.
- No second Telegram inbound poller.
- No automatic paid fallback or plan upgrade.
- No unbounded retry loop or unbounded parallelism.
- No unsigned Tailscale/webhook event may trigger an actuator.
- No external write, release, OAuth action, or physical action without its required gate.
- No claim of PC, Pi, browser, or provider success without fresh readback evidence.
- No raw credential, token, authorization header, or secret-like payload in logs or receipts.

## 8. Fastest safe activation order

1. Keep the existing Supabase event/algorithm path as the always-available hot path.
2. Keep n8n high-frequency workflows held until quota state changes; use direct RPC/events meanwhile.
3. Project only compact receipt pointers to GitHub, Linear, Notion, and ButlerBrain.
4. On the Windows PC, obtain fresh OpenClaw/OpenCode/Tailscale attestation before enabling code or private-network workers.
5. Complete Atlassian Teamwork Graph OAuth and verify permission-aware readback.
6. Run Webcmd in read-only canary mode, then promote only a stable learned macro.
7. Keep Semrush and Qlynk outside the hot path and invoke them only for bounded research or agent-build jobs.

This contract is additive and does not activate a new scheduler, paid route, physical actuator, browser writer, or production release.
