import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 16_384;
const MAX_CONTEXT_BYTES = 8_192;
const MAX_PER_HOUR = 120;
const SOURCE_TYPES = new Set([
  "pi",
  "openclaw",
  "telegram",
  "docker",
  "mcp",
  "n8n",
  "github",
  "notion",
  "manual",
  "other",
]);
const PATTERN_KINDS = new Set([
  "error",
  "repeated_reasoning",
  "workflow",
  "latency",
  "cost",
  "compatibility",
  "credential",
  "availability",
  "data_quality",
  "security",
  "other",
]);
const ALLOWED_ROLES = new Set(["pi-gateway-client", "pattern-observer"]);
const SECRET_LIKE = /(sk-proj-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|tskey-(?:auth|api|client)-[A-Za-z0-9_-]{12,}|dckr_(?:pat|oat)_[A-Za-z0-9_-]{8,}|Bearer\s+[A-Za-z0-9._~+/-]{16,}|BEGIN\s+(?:RSA|OPENSSH|EC)\s+PRIVATE\s+KEY)/i;

type JsonRecord = Record<string, unknown>;
type KeyMap = Record<string, string>;

function parseNamed(raw: string | undefined): KeyMap {
  if (!raw) return {};
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter(([, item]) =>
        typeof item === "string" && item.length > 0
      ),
    ) as KeyMap;
  } catch {
    return {};
  }
}

const secretSet = parseNamed(Deno.env.get("SUPABASE_SECRET_KEYS"));
const adminKey = secretSet.default ?? Object.values(secretSet)[0] ??
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const admin = createClient(SUPABASE_URL, adminKey, {
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

function boundedString(
  value: unknown,
  minimum: number,
  maximum: number,
): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text.length >= minimum && text.length <= maximum ? text : null;
}

function boundedInteger(
  value: unknown,
  minimum: number,
  maximum: number,
  fallback: number,
): number {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.max(minimum, Math.min(maximum, Math.trunc(number)));
}

async function parseBody(req: Request): Promise<JsonRecord | Response> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    return reply(
      { ok: false, error: "payload_too_large", secret_values_included: false },
      413,
    );
  }
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    return reply(
      { ok: false, error: "payload_too_large", secret_values_included: false },
      413,
    );
  }
  try {
    const value = JSON.parse(raw || "{}");
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new Error();
    }
    return value as JsonRecord;
  } catch {
    return reply(
      { ok: false, error: "invalid_json", secret_values_included: false },
      400,
    );
  }
}

async function authenticate(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7).trim();
  if (token.length < 20) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  const role = String(data.user.app_metadata?.role ?? "");
  if (!ALLOWED_ROLES.has(role)) return null;
  return { user: data.user, role };
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey) {
    return reply(
      { ok: false, error: "server_not_configured", secret_values_included: false },
      503,
    );
  }
  if (req.method !== "POST") {
    return reply(
      { ok: false, error: "method_not_allowed", secret_values_included: false },
      405,
    );
  }

  const actor = await authenticate(req);
  if (!actor) {
    return reply(
      { ok: false, error: "unauthorized", secret_values_included: false },
      401,
    );
  }

  const parsed = await parseBody(req);
  if (parsed instanceof Response) return parsed;
  const body = parsed;
  const executionKey = boundedString(
    body.execution_key ?? req.headers.get("x-execution-key"),
    8,
    128,
  );
  if (!executionKey) {
    return reply(
      { ok: false, error: "execution_key_required", secret_values_included: false },
      400,
    );
  }

  const { data: existing } = await admin.from("bridge_request_ledger")
    .select("request_id,allowed,reason")
    .eq("user_id", actor.user.id)
    .eq("action", "pattern_observation_intake")
    .eq("execution_key", executionKey)
    .maybeSingle();
  if (existing) {
    return reply({
      ok: false,
      error: "duplicate_execution_key",
      duplicate: true,
      secret_values_included: false,
    }, 409);
  }

  const { count, error: countError } = await admin.from("bridge_request_ledger")
    .select("request_id", { count: "exact", head: true })
    .eq("user_id", actor.user.id)
    .eq("action", "pattern_observation_intake")
    .gte("created_at", new Date(Date.now() - 3_600_000).toISOString());
  if (countError) {
    return reply(
      { ok: false, error: "rate_limit_check_failed", secret_values_included: false },
      503,
    );
  }
  if ((count ?? 0) >= MAX_PER_HOUR) {
    await admin.from("bridge_request_ledger").insert({
      user_id: actor.user.id,
      action: "pattern_observation_intake",
      execution_key: executionKey,
      allowed: false,
      duplicate: false,
      reason: "rate_limit_exceeded",
    });
    return reply(
      { ok: false, error: "rate_limit_exceeded", secret_values_included: false },
      429,
    );
  }

  const sourceType = boundedString(body.source_type, 2, 40);
  const patternKind = boundedString(body.pattern_kind, 2, 40);
  const title = boundedString(body.canonical_title, 3, 240);
  const summary = boundedString(body.redacted_summary, 3, 4000);
  if (!sourceType || !SOURCE_TYPES.has(sourceType)) {
    return reply(
      { ok: false, error: "source_type_not_allowed", secret_values_included: false },
      400,
    );
  }
  if (!patternKind || !PATTERN_KINDS.has(patternKind)) {
    return reply(
      { ok: false, error: "pattern_kind_not_allowed", secret_values_included: false },
      400,
    );
  }
  if (!title || !summary) {
    return reply(
      { ok: false, error: "title_and_redacted_summary_required", secret_values_included: false },
      400,
    );
  }

  const context = body.context && typeof body.context === "object" &&
      !Array.isArray(body.context)
    ? body.context as JsonRecord
    : {};
  const contextBytes = new TextEncoder().encode(JSON.stringify(context)).byteLength;
  if (contextBytes > MAX_CONTEXT_BYTES) {
    return reply(
      { ok: false, error: "context_too_large", secret_values_included: false },
      413,
    );
  }
  if (SECRET_LIKE.test(JSON.stringify({ title, summary, context }))) {
    return reply(
      { ok: false, error: "secret_like_content_rejected", secret_values_included: false },
      400,
    );
  }

  const sourceRef = boundedString(body.source_ref, 1, 240);
  const errorCode = boundedString(body.error_code, 1, 240);
  const fingerprint = boundedString(body.fingerprint, 64, 64);
  if (fingerprint && !/^[0-9a-f]{64}$/i.test(fingerprint)) {
    return reply(
      { ok: false, error: "fingerprint_invalid", secret_values_included: false },
      400,
    );
  }

  const { data, error } = await admin.rpc("bridge_record_pattern_observation", {
    p_source_type: sourceType,
    p_source_ref: sourceRef,
    p_pattern_kind: patternKind,
    p_canonical_title: title,
    p_redacted_summary: summary,
    p_error_code: errorCode,
    p_context: {
      ...context,
      actor_role: actor.role,
      raw_logs_copied: false,
      secret_values_included: false,
    },
    p_occurrence_count: boundedInteger(body.occurrence_count, 1, 10_000, 1),
    p_first_seen: typeof body.first_seen === "string"
      ? body.first_seen
      : new Date().toISOString(),
    p_last_seen: typeof body.last_seen === "string"
      ? body.last_seen
      : new Date().toISOString(),
    p_estimated_reasoning_tokens: boundedInteger(
      body.estimated_reasoning_tokens,
      0,
      10_000_000,
      0,
    ),
    p_estimated_recovery_seconds: boundedInteger(
      body.estimated_recovery_seconds,
      0,
      31_536_000,
      0,
    ),
    p_user_impact: boundedInteger(body.user_impact, 0, 100, 50),
    p_automation_fit: boundedInteger(body.automation_fit, 0, 100, 50),
    p_reversibility: boundedInteger(body.reversibility, 0, 100, 50),
    p_confidence: boundedInteger(body.confidence, 0, 100, 50),
    p_security_risk: boundedInteger(body.security_risk, 0, 100, 20),
    p_fingerprint: fingerprint?.toLowerCase() ?? null,
  });

  await admin.from("bridge_request_ledger").insert({
    user_id: actor.user.id,
    action: "pattern_observation_intake",
    execution_key: executionKey,
    allowed: !error,
    duplicate: false,
    reason: error ? "pattern_observation_rejected" : "admitted",
  });

  if (error) {
    return reply(
      { ok: false, error: "pattern_observation_write_failed", secret_values_included: false },
      500,
    );
  }

  const candidate = data && typeof data === "object" ? data as JsonRecord : {};
  await admin.from("bridge_events").insert({
    event_type: "pattern_observation_recorded",
    node_name: sourceType,
    correlation_id: boundedString(body.correlation_id, 1, 128),
    severity: "info",
    outcome: "succeeded",
    detail: {
      actor_user_id: actor.user.id,
      actor_role: actor.role,
      fingerprint: candidate.fingerprint ?? null,
      pattern_kind: patternKind,
      priority_score: candidate.priority_score ?? null,
      raw_logs_copied: false,
      secret_values_included: false,
    },
    created_at: new Date().toISOString(),
  });

  return reply({
    ok: true,
    candidate: {
      fingerprint: candidate.fingerprint ?? null,
      state: candidate.state ?? null,
      total_occurrences: candidate.total_occurrences ?? null,
      priority_score: candidate.priority_score ?? null,
      risk_score: candidate.risk_score ?? null,
      translation_state: candidate.translation_state ?? null,
    },
    duplicate: false,
    raw_logs_copied: false,
    secret_values_included: false,
  });
});
