import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 32 * 1024;
const MAX_SAFE_CONTEXT_BYTES = 16 * 1024;
const MAX_MUTATIONS_PER_HOUR = 60;
const CATEGORIES = new Set([
  "error",
  "reasoning",
  "operation",
  "approval",
  "compatibility",
  "data_quality",
  "credential",
  "routing",
  "observability",
]);
const FEEDBACK_OUTCOMES = new Set([
  "succeeded",
  "failed",
  "blocked",
  "rolled_back",
  "cancelled",
]);
const FORBIDDEN_EXECUTION_KEYS = new Set([
  "command",
  "commands",
  "shell",
  "argv",
  "executable",
  "script",
  "source_code",
  "payload_code",
]);
const SECRET_LIKE = /(sk-proj-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{16,}|tskey-(?:auth|api|client)-[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._~+/-]{16,}|BEGIN\s+(?:RSA|OPENSSH|EC)\s+PRIVATE\s+KEY)/i;

type JsonRecord = Record<string, unknown>;
type KeyMap = Record<string, string>;

function parseNamed(raw: string | undefined): KeyMap {
  if (!raw) return {};
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter(([, item]) => typeof item === "string" && item.length > 0),
    ) as KeyMap;
  } catch {
    return {};
  }
}

const secretSet = parseNamed(Deno.env.get("SUPABASE_SECRET_KEYS"));
const adminKey = secretSet.default ?? Object.values(secretSet)[0] ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const admin = createClient(SUPABASE_URL, adminKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function reply(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store, no-cache, must-revalidate, private",
      "pragma": "no-cache",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
}

function fail(error: string, status: number): Response {
  return reply({
    ok: false,
    error,
    values_exposed: false,
    provider_secret_returned: false,
    server_secret_returned: false,
    arbitrary_execution_allowed: false,
    secret_values_included: false,
  }, status);
}

function bounded(value: unknown, min: number, max: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text.length >= min && text.length <= max ? text : null;
}

function record(value: unknown): JsonRecord {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonRecord
    : {};
}

function containsForbiddenExecutionKey(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(containsForbiddenExecutionKey);
  if (!value || typeof value !== "object") return false;
  for (const [key, item] of Object.entries(value as JsonRecord)) {
    if (FORBIDDEN_EXECUTION_KEYS.has(key.toLowerCase())) return true;
    if (containsForbiddenExecutionKey(item)) return true;
  }
  return false;
}

function safeObject(value: unknown): JsonRecord | null {
  const object = record(value);
  const serialized = JSON.stringify(object);
  if (new TextEncoder().encode(serialized).byteLength > MAX_SAFE_CONTEXT_BYTES) return null;
  if (SECRET_LIKE.test(serialized) || containsForbiddenExecutionKey(object)) return null;
  return object;
}

async function parseBody(req: Request): Promise<JsonRecord | Response> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return fail("payload_too_large", 413);
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) return fail("payload_too_large", 413);
  try {
    const value = JSON.parse(raw || "{}");
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    if (SECRET_LIKE.test(raw)) return fail("secret_like_payload_rejected", 400);
    return value as JsonRecord;
  } catch {
    return fail("invalid_json", 400);
  }
}

async function authenticate(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7).trim();
  if (token.length < 20 || token.length > 8192) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  if (data.user.app_metadata?.role !== "pi-gateway-client") return null;
  return data.user;
}

async function reserveExecution(userId: string, action: string, executionKey: string): Promise<Response | null> {
  const { count, error: countError } = await admin
    .from("bridge_request_ledger")
    .select("request_id", { count: "exact", head: true })
    .eq("user_id", userId)
    .in("action", ["pattern_observe", "pattern_feedback"])
    .gte("created_at", new Date(Date.now() - 3_600_000).toISOString());
  if (countError) return fail("rate_limit_check_failed", 503);
  if ((count ?? 0) >= MAX_MUTATIONS_PER_HOUR) return fail("rate_limit_exceeded", 429);

  const { error } = await admin.from("bridge_request_ledger").insert({
    user_id: userId,
    action,
    execution_key: executionKey,
    allowed: false,
    duplicate: false,
    reason: "processing",
  });
  if (error?.code === "23505") return fail("duplicate_execution_key", 409);
  if (error) return fail("execution_reservation_failed", 503);
  return null;
}

async function finishExecution(userId: string, action: string, executionKey: string, allowed: boolean, reason: string) {
  await admin.from("bridge_request_ledger").update({
    allowed,
    duplicate: false,
    reason,
  }).eq("user_id", userId).eq("action", action).eq("execution_key", executionKey);
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey) return fail("server_not_configured", 503);
  if (req.method !== "POST") return fail("method_not_allowed", 405);

  const user = await authenticate(req);
  if (!user) return fail("pi_gateway_identity_required", 401);

  const parsed = await parseBody(req);
  if (parsed instanceof Response) return parsed;
  const body = parsed;
  const action = bounded(body.action, 1, 40) ?? "status";

  if (action === "status") {
    const [patterns, observations, capabilities, top] = await Promise.all([
      admin.from("openclaw_pattern_candidates").select("pattern_key", { count: "exact", head: true }),
      admin.from("openclaw_pattern_observations").select("observation_id", { count: "exact", head: true }),
      admin.from("openclaw_capability_registry").select("capability_key", { count: "exact", head: true }).in("status", ["active", "degraded"]),
      admin.from("openclaw_pattern_promotion_queue")
        .select("pattern_key,title_ko,title_en,category,status,risk_level,frequency_30d,promotion_score,ci_state,e2e_state,skill_name,next_action")
        .limit(10),
    ]);
    if (patterns.error || observations.error || capabilities.error || top.error) return fail("pattern_status_read_failed", 503);
    return reply({
      ok: true,
      engine_version: 1,
      counts: {
        patterns: patterns.count ?? 0,
        observations: observations.count ?? 0,
        active_capabilities: capabilities.count ?? 0,
      },
      top_patterns: top.data ?? [],
      promotion_policy: {
        automatic_high_risk_promotion: false,
        active_requires_low_risk: true,
        active_requires_ci_and_e2e: true,
        active_requires_rollback_and_verification: true,
      },
      values_exposed: false,
      provider_secret_returned: false,
      server_secret_returned: false,
      arbitrary_execution_allowed: false,
      secret_values_included: false,
    });
  }

  if (action === "candidates") {
    const requested = Number(body.limit ?? 10);
    const limit = Number.isFinite(requested) ? Math.max(1, Math.min(Math.trunc(requested), 20)) : 10;
    const status = bounded(body.status, 1, 40);
    let query = admin.from("openclaw_pattern_promotion_queue")
      .select("pattern_key,title_ko,title_en,category,status,risk_level,deterministic,reversible,requires_approval,frequency_30d,frequency_90d,posterior_success,promotion_score,ci_state,e2e_state,skill_name,next_action,last_observed_at")
      .limit(limit);
    if (status) query = query.eq("status", status);
    const { data, error } = await query;
    if (error) return fail("pattern_candidates_read_failed", 503);
    return reply({
      ok: true,
      candidates: data ?? [],
      values_exposed: false,
      provider_secret_returned: false,
      server_secret_returned: false,
      arbitrary_execution_allowed: false,
      secret_values_included: false,
    });
  }

  if (action === "resolve") {
    const intentKey = bounded(body.intent_key, 3, 120);
    const context = safeObject(body.context ?? {});
    if (!intentKey) return fail("valid_intent_key_required", 400);
    if (!context) return fail("safe_context_required", 400);
    const { data, error } = await admin.rpc("openclaw_resolve_capability", {
      p_intent_key: intentKey,
      p_context: context,
    });
    if (error) return fail("capability_resolution_failed", 503);
    return reply({
      ok: true,
      resolution: data,
      values_exposed: false,
      provider_secret_returned: false,
      server_secret_returned: false,
      arbitrary_execution_allowed: false,
      secret_values_included: false,
    });
  }

  if (!["observe", "feedback"].includes(action)) return fail("unsupported_action", 400);
  if (containsForbiddenExecutionKey(body)) return fail("executable_payload_field_rejected", 400);

  const executionKey = bounded(body.execution_key ?? req.headers.get("x-execution-key"), 3, 160);
  if (!executionKey) return fail("execution_key_required", 400);
  const ledgerAction = action === "observe" ? "pattern_observe" : "pattern_feedback";
  const reservation = await reserveExecution(user.id, ledgerAction, executionKey);
  if (reservation) return reservation;

  if (action === "observe") {
    const patternKey = bounded(body.pattern_key, 3, 120);
    const category = bounded(body.category, 3, 40);
    const outcome = bounded(body.outcome, 1, 120) ?? "observed";
    const severity = bounded(body.severity, 1, 20) ?? "info";
    const safeContext = safeObject(body.safe_context ?? {});
    if (!patternKey || !category || !CATEGORIES.has(category)) {
      await finishExecution(user.id, ledgerAction, executionKey, false, "invalid_pattern_or_category");
      return fail("valid_pattern_and_category_required", 400);
    }
    if (!safeContext) {
      await finishExecution(user.id, ledgerAction, executionKey, false, "unsafe_context");
      return fail("safe_context_required", 400);
    }
    const success = typeof body.success === "boolean" ? body.success : null;
    const durationMs = Number.isFinite(Number(body.duration_ms)) ? Math.max(0, Math.min(Math.trunc(Number(body.duration_ms)), 86_400_000)) : null;
    const tokensSaved = Number.isFinite(Number(body.tokens_saved_estimate)) ? Math.max(0, Math.min(Math.trunc(Number(body.tokens_saved_estimate)), 1_000_000)) : 0;
    const minutesSaved = Number.isFinite(Number(body.minutes_saved_estimate)) ? Math.max(0, Math.min(Number(body.minutes_saved_estimate), 10_000)) : 0;
    const { data, error } = await admin.rpc("openclaw_register_pattern_observation", {
      p_pattern_key: patternKey,
      p_category: category,
      p_source_system: "pi-pattern-engine",
      p_source_ref: `pi:${user.id}:${executionKey}`,
      p_severity: severity,
      p_outcome: outcome,
      p_success: success,
      p_duration_ms: durationMs,
      p_tokens_saved_estimate: tokensSaved,
      p_minutes_saved_estimate: minutesSaved,
      p_safe_context: { ...safeContext, pi_user_id: user.id, secret_values_included: false },
      p_occurred_at: new Date().toISOString(),
    });
    if (error) {
      await finishExecution(user.id, ledgerAction, executionKey, false, "observation_rejected");
      return fail(error.message.includes("secret_like") ? "secret_like_context_rejected" : "pattern_observation_failed", 400);
    }
    await finishExecution(user.id, ledgerAction, executionKey, true, "recorded");
    return reply({
      ok: true,
      observation_id: data,
      execution_key: executionKey,
      values_exposed: false,
      provider_secret_returned: false,
      server_secret_returned: false,
      arbitrary_execution_allowed: false,
      secret_values_included: false,
    });
  }

  const patternKey = bounded(body.pattern_key, 3, 120);
  const outcome = bounded(body.outcome, 3, 40);
  const safeEvidence = safeObject(body.safe_evidence ?? {});
  const reward = Number(body.reward);
  if (!patternKey || !outcome || !FEEDBACK_OUTCOMES.has(outcome) || !Number.isFinite(reward) || reward < -1 || reward > 1) {
    await finishExecution(user.id, ledgerAction, executionKey, false, "invalid_feedback_contract");
    return fail("valid_feedback_contract_required", 400);
  }
  if (!safeEvidence) {
    await finishExecution(user.id, ledgerAction, executionKey, false, "unsafe_evidence");
    return fail("safe_evidence_required", 400);
  }
  const { data, error } = await admin.rpc("openclaw_record_pattern_feedback", {
    p_pattern_key: patternKey,
    p_execution_key: `pi:${user.id}:${executionKey}`,
    p_outcome: outcome,
    p_reward: reward,
    p_skill_name: bounded(body.skill_name, 1, 120),
    p_skill_version: Number.isFinite(Number(body.skill_version)) ? Math.max(1, Math.trunc(Number(body.skill_version))) : null,
    p_latency_ms: Number.isFinite(Number(body.latency_ms)) ? Math.max(0, Math.min(Math.trunc(Number(body.latency_ms)), 86_400_000)) : null,
    p_input_tokens: Number.isFinite(Number(body.input_tokens)) ? Math.max(0, Math.min(Math.trunc(Number(body.input_tokens)), 10_000_000)) : null,
    p_output_tokens: Number.isFinite(Number(body.output_tokens)) ? Math.max(0, Math.min(Math.trunc(Number(body.output_tokens)), 10_000_000)) : null,
    p_manual_intervention: body.manual_intervention === true,
    p_error_code: bounded(body.error_code, 1, 120),
    p_safe_evidence: { ...safeEvidence, pi_user_id: user.id, secret_values_included: false },
  });
  if (error) {
    await finishExecution(user.id, ledgerAction, executionKey, false, "feedback_rejected");
    return fail(error.message.includes("secret_like") ? "secret_like_evidence_rejected" : "pattern_feedback_failed", 400);
  }
  await finishExecution(user.id, ledgerAction, executionKey, true, "recorded");
  return reply({
    ok: true,
    feedback_id: data,
    execution_key: executionKey,
    values_exposed: false,
    provider_secret_returned: false,
    server_secret_returned: false,
    arbitrary_execution_allowed: false,
    secret_values_included: false,
  });
});
