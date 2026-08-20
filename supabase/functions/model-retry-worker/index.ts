import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const OPENCODE_KEY = Deno.env.get("Opencode-api-key")?.trim() ?? "";
const WORKER_NAME = "supabase-model-retry-worker-v1";
const BACKOFF_SECONDS = [120, 300, 900, 2700, 7200] as const;
const MAX_OUTPUT_CHARS = 4000;

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

function resolveAdminKey(): string {
  const modern = parseNamed(Deno.env.get("SUPABASE_SECRET_KEYS"));
  if (modern.default) return modern.default;
  const first = Object.values(modern)[0];
  if (first) return first;
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

const ADMIN_KEY = resolveAdminKey();
const admin = createClient(SUPABASE_URL, ADMIN_KEY, {
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
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .map((item) => item.toString(16).padStart(2, "0"))
    .join("");
}

async function authorized(req: Request): Promise<boolean> {
  const token = req.headers.get("x-openclaw-worker-token")?.trim() ?? "";
  if (token.length < 32 || token.length > 256) return false;
  const hash = await sha256Hex(token);
  const { data, error } = await admin.rpc("bridge_verify_model_retry_worker_token", {
    p_token_hash: hash,
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

function extractText(data: unknown): string {
  if (!data || typeof data !== "object") return "";
  const record = data as Record<string, any>;
  if (typeof record.output_text === "string" && record.output_text.trim()) {
    return record.output_text.trim().slice(0, MAX_OUTPUT_CHARS);
  }
  if (Array.isArray(record.output)) {
    const parts: string[] = [];
    for (const item of record.output) {
      if (!Array.isArray(item?.content)) continue;
      for (const content of item.content) {
        if (typeof content?.text === "string") parts.push(content.text);
      }
    }
    if (parts.length) return parts.join("\n").trim().slice(0, MAX_OUTPUT_CHARS);
  }
  if (Array.isArray(record.choices)) {
    const text = record.choices[0]?.message?.content;
    if (typeof text === "string") return text.trim().slice(0, MAX_OUTPUT_CHARS);
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
        "user-agent": "openclaw-supabase-model-retry-worker/1",
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

async function completeTask(task: QueueTask, text: string, attempts: Attempt[]): Promise<void> {
  const deliveryKey = `telegram-delivery-${task.id}`;
  const correlationId = typeof task.payload?.correlation_id === "string"
    ? task.payload.correlation_id.slice(0, 128)
    : null;
  const { data: existing } = await admin
    .from("openclaw_work_queue")
    .select("id")
    .eq("task_key", deliveryKey)
    .maybeSingle();
  if (!existing) {
    await admin.from("openclaw_work_queue").insert({
      task_key: deliveryKey,
      task_type: "telegram_result_delivery",
      payload: {
        text,
        source_task_id: task.id,
        correlation_id: correlationId,
        channel: "telegram",
        delivery_mode: "openclaw_message_send",
        provider_secret_included: false,
        secret_values_included: false,
      },
      priority: 90,
      status: "queued",
      attempts: 0,
      max_attempts: 10,
      not_before: new Date().toISOString(),
      evidence: {},
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });
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
  if (!SUPABASE_URL || !ADMIN_KEY || !OPENCODE_KEY) {
    return reply({ ok: false, error: "worker_not_configured", secret_values_included: false }, 503);
  }
  if (!(await authorized(req))) {
    return reply({ ok: false, error: "unauthorized", secret_values_included: false }, 401);
  }

  const task = await claimTask();
  if (!task) {
    return reply({
      ok: true,
      claimed: 0,
      completed: 0,
      requeued: 0,
      failed: 0,
      delivery_tasks_created: 0,
      provider_secret_returned: false,
      secret_values_included: false,
    });
  }

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
    return reply({
      ok: true,
      claimed: 1,
      completed: 0,
      requeued: 1,
      failed: 0,
      delivery_tasks_created: 0,
      reason: "all_models_temporarily_quarantined",
      provider_secret_returned: false,
      secret_values_included: false,
    });
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

  let completed = 0;
  let requeued = 0;
  let failed = 0;
  let deliveryTasks = 0;
  if (success) {
    const text = extractText(success.data);
    await completeTask(task, text, attempts);
    completed = 1;
    deliveryTasks = 1;
  } else {
    const terminal = await failTask(task, attempts);
    if (terminal) failed = 1;
    else requeued = 1;
  }

  await admin.from("bridge_events").insert({
    event_type: "server_model_retry_worker_run",
    node_name: "supabase",
    correlation_id: typeof task.payload?.correlation_id === "string"
      ? task.payload.correlation_id.slice(0, 128)
      : null,
    severity: failed ? "warning" : "info",
    outcome: failed ? "failed" : completed ? "succeeded" : "queued",
    detail: {
      task_key: task.task_key,
      completed,
      requeued,
      failed,
      delivery_tasks_created: deliveryTasks,
      attempted_models: attempts.map((item) => item.model),
      statuses: attempts.map((item) => item.status),
      raw_provider_error_stored: false,
      provider_secret_returned: false,
      secret_values_included: false,
    },
    created_at: new Date().toISOString(),
  });

  return reply({
    ok: true,
    claimed: 1,
    completed,
    requeued,
    failed,
    delivery_tasks_created: deliveryTasks,
    attempted_models: attempts.map((item) => item.model),
    statuses: attempts.map((item) => item.status),
    provider_secret_returned: false,
    secret_values_included: false,
  });
});
