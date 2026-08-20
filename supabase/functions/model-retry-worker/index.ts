import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const OPENCODE_KEY = Deno.env.get("Opencode-api-key")?.trim() ?? "";
const WORKER_NAME = "supabase-model-retry-worker-v2";
const MAX_TASKS_PER_RUN = 2;
const MAX_RESULT_CHARS = 4000;
const BACKOFF_SECONDS = [120, 300, 900, 2700, 7200] as const;
const SECRET_LIKE = /(sk-proj-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]+|tskey-(?:auth|api|client)-[A-Za-z0-9_-]+|Bearer\s+[A-Za-z0-9._~+\/-]{16,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{8,}|-----BEGIN\s+(?:[A-Z]+\s+)?PRIVATE\s+KEY-----)/gi;

type JsonRecord = Record<string, unknown>;
type QueueTask = {
  id: string;
  task_key: string;
  payload: JsonRecord;
  attempts: number;
  max_attempts: number;
  evidence: JsonRecord | null;
};
type HealthRow = {
  model_id: string;
  health_status: string;
  quarantined_until: string | null;
};
type Attempt = {
  model: string;
  ok: boolean;
  status: number | null;
  latency_ms: number;
  data: unknown;
  error_type: string | null;
  timeout: boolean;
};

function parseNamed(raw: string | undefined): Record<string, string> {
  if (!raw) return {};
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter(([, item]) => typeof item === "string" && item.length > 0),
    ) as Record<string, string>;
  } catch {
    return {};
  }
}

function resolveAdminKey(): { value: string; type: string } {
  const modern = parseNamed(Deno.env.get("SUPABASE_SECRET_KEYS"));
  if (modern.default) return { value: modern.default, type: "modern_secret_default" };
  const first = Object.values(modern)[0];
  if (first) return { value: first, type: "modern_secret_named" };
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  return legacy
    ? { value: legacy, type: "legacy_service_role_compatibility" }
    : { value: "", type: "missing" };
}

const adminKey = resolveAdminKey();
const admin = createClient(SUPABASE_URL, adminKey.value, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function reply(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digestInput = bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
  const digest = await crypto.subtle.digest("SHA-256", digestInput);
  return [...new Uint8Array(digest)]
    .map((item) => item.toString(16).padStart(2, "0"))
    .join("");
}

async function authorized(req: Request): Promise<boolean> {
  const token = req.headers.get("x-openclaw-scheduler-token")?.trim() ?? "";
  if (token.length < 32 || token.length > 256) return false;
  const tokenHash = await sha256Hex(token);
  const { data, error } = await admin.rpc("bridge_verify_model_retry_worker_token", {
    p_token_hash: tokenHash,
  });
  return !error && data === true;
}

function normalizeModel(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const model = value.trim();
  if (!model || model.length > 160) return null;
  for (const prefix of ["supabase-opencode/", "opencode/"]) {
    if (model.startsWith(prefix)) return model.slice(prefix.length);
  }
  return model;
}

function unique(values: string[]): string[] {
  return [...new Set(values.filter(Boolean))];
}

function isQuarantined(row: HealthRow | undefined): boolean {
  if (!row || row.health_status !== "quarantined") return false;
  if (!row.quarantined_until) return true;
  return new Date(row.quarantined_until).getTime() > Date.now();
}

function redactText(value: string): string {
  return value.replace(SECRET_LIKE, "[REDACTED]").slice(0, MAX_RESULT_CHARS);
}

function extractText(data: unknown): string {
  if (!data || typeof data !== "object") return "";
  const record = data as Record<string, any>;
  if (typeof record.output_text === "string" && record.output_text.trim()) {
    return redactText(record.output_text.trim());
  }
  if (Array.isArray(record.output)) {
    const parts: string[] = [];
    for (const item of record.output) {
      if (!Array.isArray(item?.content)) continue;
      for (const content of item.content) {
        if (typeof content?.text === "string") parts.push(content.text);
      }
    }
    if (parts.length) return redactText(parts.join("\n").trim());
  }
  if (Array.isArray(record.choices)) {
    const text = record.choices[0]?.message?.content;
    if (typeof text === "string") return redactText(text.trim());
  }
  return "";
}

function errorType(data: unknown): string | null {
  if (!data || typeof data !== "object") return null;
  const error = (data as JsonRecord).error;
  if (!error || typeof error !== "object") return null;
  const item = error as JsonRecord;
  const value = item.type ?? item.code;
  return typeof value === "string" ? value.slice(0, 120) : null;
}

function quarantineSeconds(attempt: Attempt): number | null {
  if (attempt.timeout) return 60;
  if (attempt.status === 429) return 21_600;
  if (attempt.status === 408 || attempt.status === 425) return 60;
  if (attempt.status !== null && attempt.status >= 500) return 120;
  return null;
}

async function loadRoute(): Promise<{ primary: string | null; fallbacks: string[] }> {
  const { data, error } = await admin
    .from("bridge_canonical_config")
    .select("config_value")
    .eq("config_key", "model.runtime_route")
    .eq("enabled", true)
    .maybeSingle();
  if (error || !data?.config_value || typeof data.config_value !== "object") {
    return { primary: null, fallbacks: [] };
  }
  const config = data.config_value as JsonRecord;
  const primary = normalizeModel(config.primary);
  const fallbacks = Array.isArray(config.fallbacks)
    ? config.fallbacks.map(normalizeModel).filter((item): item is string => Boolean(item))
    : [];
  return { primary, fallbacks: unique(fallbacks) };
}

async function loadHealth(models: string[]): Promise<Map<string, HealthRow>> {
  if (!models.length) return new Map();
  const { data } = await admin
    .from("bridge_model_health")
    .select("model_id,health_status,quarantined_until")
    .in("model_id", models);
  return new Map((data ?? []).map((row) => [row.model_id, row as HealthRow]));
}

async function claimTask(): Promise<QueueTask | null> {
  const { data, error } = await admin.rpc("bridge_claim_model_retry_task", {
    p_worker: WORKER_NAME,
    p_lease_minutes: 3,
  });
  if (error || !Array.isArray(data) || !data[0]) return null;
  return data[0] as QueueTask;
}

async function invokeModel(model: string, requestBody: JsonRecord): Promise<Attempt> {
  const started = performance.now();
  try {
    const upstream = await fetch("https://opencode.ai/zen/v1/responses", {
      method: "POST",
      headers: {
        authorization: `Bearer ${OPENCODE_KEY}`,
        "content-type": "application/json",
        "user-agent": "openclaw-supabase-model-retry-worker/4",
      },
      body: JSON.stringify({ ...requestBody, model }),
      signal: AbortSignal.timeout(35_000),
    });
    const data = await upstream.json().catch(() => ({}));
    const text = extractText(data);
    return {
      model,
      ok: upstream.ok && Boolean(text),
      status: upstream.status,
      latency_ms: Math.round(performance.now() - started),
      data,
      error_type: upstream.ok && text ? null : errorType(data),
      timeout: false,
    };
  } catch (error) {
    const timeout = error instanceof DOMException && error.name === "TimeoutError";
    return {
      model,
      ok: false,
      status: null,
      latency_ms: Math.round(performance.now() - started),
      data: {},
      error_type: timeout ? "timeout" : "upstream_unreachable",
      timeout,
    };
  }
}

async function recordAttempt(attempt: Attempt): Promise<void> {
  await admin.rpc("bridge_record_model_result", {
    p_model_id: attempt.model,
    p_success: attempt.ok,
    p_status_code: attempt.status,
    p_error_type: attempt.error_type,
    p_latency_ms: attempt.latency_ms,
    p_quarantine_seconds: attempt.ok ? null : quarantineSeconds(attempt),
  });
}

async function releaseUntil(task: QueueTask, notBefore: Date): Promise<void> {
  await admin
    .from("openclaw_work_queue")
    .update({
      status: "queued",
      attempts: Math.max(0, task.attempts - 1),
      not_before: notBefore.toISOString(),
      lease_until: null,
      claimed_by: null,
      last_error: "all_models_temporarily_quarantined",
      evidence: {
        ...(task.evidence ?? {}),
        lease_owner: null,
        last_release_reason: "all_models_temporarily_quarantined",
        provider_secret_returned: false,
        secret_values_included: false,
      },
      updated_at: new Date().toISOString(),
    })
    .eq("id", task.id)
    .eq("status", "claimed");
}

async function completeTask(task: QueueTask, text: string, attempts: Attempt[]): Promise<boolean> {
  const deliveryKey = `telegram-delivery-${task.id}`;
  const correlationId = typeof task.payload?.correlation_id === "string"
    ? task.payload.correlation_id.slice(0, 128)
    : null;
  const { data: existing } = await admin
    .from("openclaw_work_queue")
    .select("id")
    .eq("task_key", deliveryKey)
    .maybeSingle();
  let deliveryCreated = Boolean(existing);
  if (!existing) {
    const { error } = await admin.from("openclaw_work_queue").insert({
      task_key: deliveryKey,
      task_type: "telegram_result_delivery",
      payload: {
        text,
        source_task_id: task.id,
        correlation_id: correlationId,
        channel: "telegram",
        delivery_mode: "openclaw_message_send",
        existing_single_poller_only: true,
        provider_secret_included: false,
        secret_values_included: false,
      },
      priority: 90,
      status: "queued",
      attempts: 0,
      max_attempts: 20,
      not_before: new Date().toISOString(),
      evidence: {},
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });
    deliveryCreated = !error;
  }

  await admin
    .from("openclaw_work_queue")
    .update({
      status: "completed",
      lease_until: null,
      claimed_by: null,
      completed_at: new Date().toISOString(),
      last_error: null,
      evidence: {
        ...(task.evidence ?? {}),
        lease_owner: null,
        output_present: true,
        output_chars: text.length,
        delivery_task_key: deliveryKey,
        delivery_task_created: deliveryCreated,
        models_attempted: attempts.map((item) => item.model),
        statuses: attempts.map((item) => item.status),
        raw_provider_error_stored: false,
        provider_secret_returned: false,
        secret_values_included: false,
      },
      updated_at: new Date().toISOString(),
    })
    .eq("id", task.id)
    .eq("status", "claimed");
  return deliveryCreated;
}

async function failTask(task: QueueTask, attempts: Attempt[]): Promise<boolean> {
  const terminal = task.attempts >= task.max_attempts;
  const delay = BACKOFF_SECONDS[Math.min(Math.max(task.attempts - 1, 0), BACKOFF_SECONDS.length - 1)];
  await admin
    .from("openclaw_work_queue")
    .update({
      status: terminal ? "failed" : "queued",
      not_before: new Date(Date.now() + delay * 1000).toISOString(),
      lease_until: null,
      claimed_by: null,
      last_error: "provider_temporarily_unavailable",
      evidence: {
        ...(task.evidence ?? {}),
        lease_owner: null,
        last_models: attempts.map((item) => item.model),
        last_statuses: attempts.map((item) => item.status),
        raw_provider_error_stored: false,
        provider_secret_returned: false,
        secret_values_included: false,
      },
      updated_at: new Date().toISOString(),
    })
    .eq("id", task.id)
    .eq("status", "claimed");
  return terminal;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply({ ok: false, error: "method_not_allowed" }, 405);
  if (!SUPABASE_URL || !adminKey.value || !OPENCODE_KEY) {
    return reply({ ok: false, error: "worker_not_configured", secret_values_included: false }, 503);
  }
  if (!(await authorized(req))) {
    return reply({
      ok: false,
      error: "unauthorized",
      vault_auth_verified: false,
      provider_secret_returned: false,
      secret_values_included: false,
    }, 401);
  }

  let claimed = 0;
  let completed = 0;
  let requeued = 0;
  let failed = 0;
  let deliveryTasks = 0;

  for (let index = 0; index < MAX_TASKS_PER_RUN; index++) {
    const task = await claimTask();
    if (!task) break;
    claimed++;

    const requestBody = task.payload?.request && typeof task.payload.request === "object"
      ? task.payload.request as JsonRecord
      : {};
    const route = await loadRoute();
    const configured = unique([route.primary ?? "", ...route.fallbacks]);
    const health = await loadHealth(configured);
    const active = configured.filter((model) => !isQuarantined(health.get(model))).slice(0, 2);

    if (!active.length) {
      const nextProbe = [...health.values()]
        .map((item) => item.quarantined_until ? new Date(item.quarantined_until).getTime() : Number.NaN)
        .filter(Number.isFinite)
        .sort((a, b) => a - b)[0];
      await releaseUntil(task, new Date(Math.max(Date.now() + 300_000, nextProbe || 0)));
      requeued++;
      continue;
    }

    const attempts: Attempt[] = [];
    let success: Attempt | null = null;
    for (const model of active) {
      const attempt = await invokeModel(model, requestBody);
      attempts.push(attempt);
      await recordAttempt(attempt);
      if (attempt.ok) {
        success = attempt;
        break;
      }
    }

    if (success) {
      const text = extractText(success.data);
      if (await completeTask(task, text, attempts)) deliveryTasks++;
      completed++;
    } else {
      const terminal = await failTask(task, attempts);
      if (terminal) failed++;
      else requeued++;
    }
  }

  await admin.from("bridge_events").insert({
    event_type: "server_model_retry_worker_run_v4",
    node_name: "supabase",
    correlation_id: crypto.randomUUID(),
    severity: failed ? "warning" : "info",
    outcome: failed ? "failed" : "succeeded",
    detail: {
      claimed,
      completed,
      requeued,
      failed,
      telegram_delivery_tasks_created: deliveryTasks,
      vault_auth_verified: true,
      runtime_server_key_type: adminKey.type,
      direct_telegram_get_updates: false,
      raw_provider_error_stored: false,
      provider_secret_returned: false,
      secret_values_included: false,
    },
    created_at: new Date().toISOString(),
  });

  return reply({
    ok: true,
    claimed,
    completed,
    requeued,
    failed,
    telegram_delivery_tasks_created: deliveryTasks,
    vault_auth_verified: true,
    runtime_server_key_type: adminKey.type,
    direct_telegram_get_updates: false,
    provider_secret_returned: false,
    secret_values_included: false,
  });
});
