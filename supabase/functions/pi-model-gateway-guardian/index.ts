import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const OPENCODE_KEY = Deno.env.get("Opencode-api-key")?.trim() ?? "";
const MAX_BODY_BYTES = 65_536;
const MAX_ATTEMPTS = 2;
const SECRET_LIKE = /(sk-proj-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]+|tskey-[A-Za-z0-9_-]+|Bearer\s+[A-Za-z0-9._~-]{16,}|BEGIN\s+(RSA|OPENSSH|EC)\s+PRIVATE\s+KEY)/gi;

type JsonRecord = Record<string, unknown>;
type HealthRow = {
  model_id: string;
  health_status: string;
  quarantined_until: string | null;
};
type AttemptResult = {
  model: string;
  ok: boolean;
  status: number | null;
  latencyMs: number;
  data: unknown;
  errorType: string | null;
  timeout: boolean;
};

function parseNamed(raw: string | undefined): Record<string, string> {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return Object.fromEntries(
      Object.entries(parsed).filter(([, value]) => typeof value === "string" && value.length > 0),
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

function response(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
      ...extra,
    },
  });
}

function fail(error: string, status: number): Response {
  return response({
    error: { message: error, type: "gateway_error", code: error },
    provider_secret_returned: false,
    values_logged: false,
  }, status);
}

function normalizeModel(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > 160) return null;
  for (const prefix of ["supabase-opencode/", "opencode/"]) {
    if (trimmed.startsWith(prefix)) return trimmed.slice(prefix.length);
  }
  return trimmed;
}

function unique(values: string[]): string[] {
  return [...new Set(values.filter(Boolean))];
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

function isQuarantined(row: HealthRow | undefined): boolean {
  if (!row || row.health_status !== "quarantined") return false;
  if (!row.quarantined_until) return true;
  return new Date(row.quarantined_until).getTime() > Date.now();
}

function extractErrorType(data: unknown): string | null {
  if (!data || typeof data !== "object") return null;
  const record = data as JsonRecord;
  const error = record.error;
  if (!error || typeof error !== "object") return null;
  const errorRecord = error as JsonRecord;
  const candidate = errorRecord.type ?? errorRecord.code;
  return typeof candidate === "string" ? candidate.slice(0, 120) : null;
}

function quarantineSeconds(result: AttemptResult): number | null {
  if (result.timeout) return 60;
  if (result.status === 429) return 21_600;
  if (result.status !== null && result.status >= 500) return 120;
  if (result.status === 408 || result.status === 425) return 60;
  return null;
}

function safeQueuedPayload(value: unknown): unknown {
  const serialized = JSON.stringify(value);
  const redacted = serialized.replace(SECRET_LIKE, "[REDACTED]");
  return JSON.parse(redacted);
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function requirePi(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7).trim();
  if (token.length < 20) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  if (data.user.app_metadata?.role !== "pi-gateway-client") return null;
  return data.user;
}

async function loadRoute(): Promise<{ primary: string | null; fallbacks: string[]; utility: string | null }> {
  const { data, error } = await admin
    .from("bridge_canonical_config")
    .select("config_value")
    .eq("config_key", "model.runtime_route")
    .eq("enabled", true)
    .maybeSingle();
  if (error || !data?.config_value || typeof data.config_value !== "object") {
    return { primary: null, fallbacks: [], utility: null };
  }
  const config = data.config_value as JsonRecord;
  const primary = normalizeModel(config.primary);
  const fallbacks = Array.isArray(config.fallbacks)
    ? config.fallbacks.map(normalizeModel).filter((id): id is string => Boolean(id))
    : [];
  const utility = normalizeModel(config.utility_model) ?? primary;
  return { primary, fallbacks: unique(fallbacks), utility };
}

async function loadHealth(models: string[]): Promise<Map<string, HealthRow>> {
  if (models.length === 0) return new Map();
  const { data } = await admin
    .from("bridge_model_health")
    .select("model_id,health_status,quarantined_until")
    .in("model_id", models);
  return new Map((data ?? []).map((row) => [row.model_id, row as HealthRow]));
}

async function recordResult(result: AttemptResult): Promise<void> {
  await admin.rpc("bridge_record_model_result", {
    p_model_id: result.model,
    p_success: result.ok,
    p_status_code: result.status,
    p_error_type: result.errorType,
    p_latency_ms: result.latencyMs,
    p_quarantine_seconds: result.ok ? null : quarantineSeconds(result),
  });
}

async function invokeModel(model: string, body: JsonRecord): Promise<AttemptResult> {
  const started = performance.now();
  try {
    const upstream = await fetch("https://opencode.ai/zen/v1/responses", {
      method: "POST",
      headers: {
        authorization: `Bearer ${OPENCODE_KEY}`,
        "content-type": "application/json",
        "user-agent": "openclaw-supabase-model-guardian/1",
      },
      body: JSON.stringify({ ...body, model }),
      signal: AbortSignal.timeout(35_000),
    });
    const data = await upstream.json().catch(() => ({}));
    const outputPresent = Boolean(
      (typeof data?.output_text === "string" && data.output_text.length > 0) ||
      (Array.isArray(data?.output) && data.output.length > 0) ||
      (Array.isArray(data?.choices) && data.choices.length > 0)
    );
    return {
      model,
      ok: upstream.ok && outputPresent,
      status: upstream.status,
      latencyMs: Math.round(performance.now() - started),
      data,
      errorType: upstream.ok && outputPresent ? null : extractErrorType(data),
      timeout: false,
    };
  } catch (error) {
    const timeout = error instanceof DOMException && error.name === "TimeoutError";
    return {
      model,
      ok: false,
      status: null,
      latencyMs: Math.round(performance.now() - started),
      data: {},
      errorType: timeout ? "timeout" : "upstream_unreachable",
      timeout,
    };
  }
}

function queuedResponse(queueId: string, retryAfter: number): JsonRecord {
  const text = `요청을 안전하게 보존했습니다. AI 서비스 복구 후 자동 재시도합니다. 작업 ID: ${queueId}`;
  return {
    id: `resp_queued_${queueId}`,
    object: "response",
    created_at: nowSeconds(),
    status: "completed",
    background: false,
    error: null,
    incomplete_details: null,
    instructions: null,
    max_output_tokens: null,
    model: "openclaw-queued",
    output: [{
      id: `msg_${queueId}`,
      type: "message",
      status: "completed",
      role: "assistant",
      content: [{
        type: "output_text",
        text,
        annotations: [],
        logprobs: [],
      }],
    }],
    output_text: text,
    parallel_tool_calls: true,
    previous_response_id: null,
    reasoning: { effort: null, summary: null },
    store: false,
    temperature: null,
    text: { format: { type: "text" } },
    tool_choice: "auto",
    tools: [],
    top_p: null,
    truncation: "disabled",
    usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0 },
    user: null,
    metadata: {
      openclaw_queued: "true",
      retry_after_seconds: String(retryAfter),
      provider_error_hidden: "true",
    },
  };
}

async function queueRequest(
  userId: string,
  req: Request,
  body: JsonRecord,
  attempts: AttemptResult[],
): Promise<{ queueId: string; retryAfter: number }> {
  const explicit = req.headers.get("x-idempotency-key")?.trim() ?? "";
  const bucket = Math.floor(Date.now() / 300_000);
  const fingerprint = explicit || await sha256(`${userId}:${bucket}:${JSON.stringify(body)}`);
  const queueId = fingerprint.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 40) || crypto.randomUUID().replaceAll("-", "").slice(0, 24);
  const taskKey = `model-retry-${queueId}`;
  const correlationId = req.headers.get("x-correlation-id")?.slice(0, 128) ?? null;
  const retryAfter = 120;
  const payload = safeQueuedPayload({
    request: body,
    requested_model: body.model ?? null,
    attempts: attempts.map((attempt) => ({
      model: attempt.model,
      status: attempt.status,
      error_type: attempt.errorType,
      latency_ms: attempt.latencyMs,
    })),
    correlation_id: correlationId,
    retry_policy: {
      backoff_seconds: [120, 300, 900, 2700, 7200],
      max_attempts: 5,
      surface_raw_provider_error_to_telegram: false,
    },
    provider_secret_included: false,
  });

  const { data: existing } = await admin
    .from("openclaw_work_queue")
    .select("id,task_key,status")
    .eq("task_key", taskKey)
    .maybeSingle();

  if (!existing) {
    await admin.from("openclaw_work_queue").insert({
      task_key: taskKey,
      task_type: "model_request_retry",
      payload,
      priority: 95,
      status: "queued",
      attempts: 0,
      max_attempts: 5,
      not_before: new Date(Date.now() + retryAfter * 1000).toISOString(),
      evidence: {},
      last_error: "provider_temporarily_unavailable",
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });
  }

  await admin.from("bridge_events").insert({
    event_type: "model_request_queued_after_provider_failure",
    node_name: "raspberry-pi5",
    correlation_id: correlationId,
    severity: "warning",
    outcome: "queued",
    detail: {
      task_key: taskKey,
      attempted_models: attempts.map((attempt) => attempt.model),
      statuses: attempts.map((attempt) => attempt.status),
      provider_error_hidden: true,
      provider_secret_returned: false,
      secret_values_included: false,
    },
    created_at: new Date().toISOString(),
  });

  return { queueId, retryAfter };
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey.value || !OPENCODE_KEY) return fail("gateway_not_configured", 503);
  const user = await requirePi(req);
  if (!user) return fail("unauthorized", 401);

  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*\/pi-model-gateway-guardian/, "");

  if (req.method === "GET" && (path === "/v1/models" || path === "/models")) {
    const route = await loadRoute();
    const ids = unique([route.primary ?? "", ...route.fallbacks]);
    const health = await loadHealth(ids);
    const active = ids.filter((id) => !isQuarantined(health.get(id)));
    return response({
      object: "list",
      data: active.map((id) => ({
        id: `supabase-opencode/${id}`,
        object: "model",
        created: 0,
        owned_by: "supabase-opencode",
      })),
      provider_secret_returned: false,
    });
  }

  if (req.method !== "POST" || (path !== "/v1/responses" && path !== "/responses")) {
    return fail("not_found", 404);
  }

  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return fail("payload_too_large", 413);
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) return fail("payload_too_large", 413);

  let body: JsonRecord;
  try {
    const parsed = JSON.parse(raw || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
    body = parsed as JsonRecord;
  } catch {
    return fail("invalid_json", 400);
  }

  const route = await loadRoute();
  if (!route.primary) return fail("canonical_model_route_missing", 503);
  const requested = normalizeModel(body.model);
  const configured = unique([route.primary, ...route.fallbacks]);
  const health = await loadHealth(configured);
  const requestedAllowed = requested && configured.includes(requested) && !isQuarantined(health.get(requested));
  const ordered = unique([
    requestedAllowed ? requested! : route.primary,
    route.primary,
    ...route.fallbacks,
  ]).filter((model) => !isQuarantined(health.get(model))).slice(0, MAX_ATTEMPTS);

  if (ordered.length === 0) {
    const queued = await queueRequest(user.id, req, body, []);
    return response(queuedResponse(queued.queueId, queued.retryAfter), 200, {
      "x-openclaw-queued": "true",
      "retry-after": String(queued.retryAfter),
    });
  }

  const attempts: AttemptResult[] = [];
  for (const model of ordered) {
    const result = await invokeModel(model, body);
    attempts.push(result);
    await recordResult(result);
    if (result.ok) {
      await admin.from("bridge_events").insert({
        event_type: "model_gateway_guardian_request_succeeded",
        node_name: "raspberry-pi5",
        correlation_id: req.headers.get("x-correlation-id")?.slice(0, 128) ?? null,
        severity: "info",
        outcome: "succeeded",
        detail: {
          model,
          attempt_number: attempts.length,
          latency_ms: result.latencyMs,
          fallback_used: attempts.length > 1,
          provider_secret_returned: false,
          secret_values_included: false,
        },
        created_at: new Date().toISOString(),
      });
      return response(result.data, 200, {
        "x-openclaw-model-route": `supabase-opencode/${model}`,
        "x-openclaw-fallback-used": attempts.length > 1 ? "true" : "false",
      });
    }
  }

  const queued = await queueRequest(user.id, req, body, attempts);
  return response(queuedResponse(queued.queueId, queued.retryAfter), 200, {
    "x-openclaw-queued": "true",
    "retry-after": String(queued.retryAfter),
  });
});