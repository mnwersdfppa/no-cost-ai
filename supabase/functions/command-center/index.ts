import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 131_072;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SECRET_LIKE = /(sk-proj-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]+|Bearer\s+[A-Za-z0-9._~+\/-]{16,}|-----BEGIN\s+(?:[A-Z]+\s+)?PRIVATE\s+KEY-----)/i;
const MUTATING_ACTIONS = new Set(["command_ingest", "decision_record", "feedback_record", "object_link"]);

type JsonRecord = Record<string, unknown>;

function parseNamedKeySet(raw: string | undefined): Record<string, string> {
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

function resolveAdminKey(): {
  value: string;
  selectedType: "modern_secret_default" | "modern_secret_named" | "legacy_service_role_compatibility" | "missing";
  modernPresent: boolean;
  legacyPresent: boolean;
} {
  const modern = parseNamedKeySet(Deno.env.get("SUPABASE_SECRET_KEYS"));
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (modern.default) {
    return {
      value: modern.default,
      selectedType: "modern_secret_default",
      modernPresent: true,
      legacyPresent: Boolean(legacy),
    };
  }
  const first = Object.values(modern)[0];
  if (typeof first === "string" && first.length > 0) {
    return {
      value: first,
      selectedType: "modern_secret_named",
      modernPresent: true,
      legacyPresent: Boolean(legacy),
    };
  }
  if (legacy) {
    return {
      value: legacy,
      selectedType: "legacy_service_role_compatibility",
      modernPresent: false,
      legacyPresent: true,
    };
  }
  return {
    value: "",
    selectedType: "missing",
    modernPresent: false,
    legacyPresent: false,
  };
}

const adminKey = resolveAdminKey();
const admin = createClient(SUPABASE_URL, adminKey.value, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function reply(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
}

function fail(code: string, status: number): Response {
  return reply({ ok: false, error: code, values_exposed: false }, status);
}

function isRecord(value: unknown): value is JsonRecord {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function boundedString(value: unknown, min: number, max: number): string | null {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result.length >= min && result.length <= max ? result : null;
}

function optionalNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
}

function optionalBoolean(value: unknown, fallback = false): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function safeJson(value: unknown, fallback: unknown): unknown {
  return value === undefined || value === null ? fallback : value;
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digestInput = bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
  const digest = await crypto.subtle.digest("SHA-256", digestInput);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function requirePi(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw fail("unauthorized", 401);
  const { data, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user) throw fail("unauthorized", 401);
  if (data.user.app_metadata?.role !== "pi-gateway-client") {
    throw fail("pi_identity_required", 403);
  }
  return data.user;
}

async function parseBody(req: Request): Promise<JsonRecord> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    throw fail("payload_too_large", 413);
  }
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    throw fail("payload_too_large", 413);
  }
  if (SECRET_LIKE.test(raw)) throw fail("secret_like_payload_rejected", 400);
  try {
    const parsed = JSON.parse(raw || "{}");
    if (!isRecord(parsed)) throw new Error("object required");
    return parsed;
  } catch {
    throw fail("invalid_json", 400);
  }
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey.value) return fail("server_not_configured", 503);
  if (!["GET", "POST"].includes(req.method)) return fail("method_not_allowed", 405);

  let user;
  try {
    user = await requirePi(req);
  } catch (response) {
    return response instanceof Response ? response : fail("authentication_failed", 401);
  }

  let body: JsonRecord = {};
  if (req.method === "POST") {
    try {
      body = await parseBody(req);
    } catch (response) {
      return response instanceof Response ? response : fail("invalid_request", 400);
    }
  }

  const action = req.method === "GET"
    ? "command_status"
    : boundedString(body.action, 1, 80) ?? "command_status";
  if (!["command_status", "command_ingest", "decision_record", "feedback_record", "object_link"].includes(action)) {
    return fail("unsupported_action", 400);
  }

  const rawExecutionKey = boundedString(
    body.execution_key ?? req.headers.get("x-execution-key"),
    1,
    128,
  );
  if (MUTATING_ACTIONS.has(action) && !rawExecutionKey) {
    return fail("execution_key_required", 400);
  }
  const ledgerExecutionKey = rawExecutionKey
    ? `cc:${await sha256Hex(`${action}:${rawExecutionKey}`)}`
    : null;

  const { data: admissionRows, error: admissionError } = await admin.rpc(
    "bridge_admit_request",
    {
      p_user_id: user.id,
      p_action: action,
      p_execution_key: ledgerExecutionKey,
    },
  );
  if (admissionError || !admissionRows?.[0]) return fail("admission_check_failed", 503);
  const admission = admissionRows[0];
  if (!admission.allowed) {
    return reply(
      { ok: false, error: admission.reason, admission, values_exposed: false },
      admission.reason === "rate_limit_exceeded" ? 429 : 403,
    );
  }
  if (admission.duplicate && MUTATING_ACTIONS.has(action) && action !== "command_ingest") {
    return reply({ ok: true, duplicate: true, admission, values_exposed: false });
  }

  await admin.rpc("bridge_record_runtime_key_selection", {
    p_user_id: user.id,
    p_function_name: "command-center",
    p_selected_key_type: adminKey.selectedType,
    p_modern_key_present: adminKey.modernPresent,
    p_legacy_key_present: adminKey.legacyPresent,
    p_value_returned: false,
  });
  await admin.rpc("bridge_reconcile_runtime_key_unification");

  if (action === "command_status") {
    const [snapshot, board, catalog, runtimeKeys] = await Promise.all([
      admin.from("command_center_snapshot").select("*").maybeSingle(),
      admin.from("command_current_board")
        .select("intent_id,objective,task_type,command_mode,authority_scope,priority_score,risk_tier,status,seen_count,duplicate_reads_avoided,possible_duplicate_of,similarity_score,deadline_at,last_seen_at")
        .limit(25),
      admin.from("command_action_catalog")
        .select("route_key,integration,route_type,endpoint_alias,mode,priority,route_enabled,health_status,credential_configured,credential_validation_status,read_only_default,policies")
        .order("priority", { ascending: true }),
      admin.from("bridge_runtime_key_selection")
        .select("function_name,selected_key_type,modern_key_present,legacy_key_present,value_returned,last_reported_at")
        .order("function_name"),
    ]);
    if (snapshot.error || board.error || catalog.error || runtimeKeys.error) {
      return fail("command_status_read_failed", 503);
    }
    return reply({
      ok: true,
      version: 2,
      admission,
      snapshot: snapshot.data,
      board: board.data ?? [],
      action_catalog: catalog.data ?? [],
      runtime_key_receipts: runtimeKeys.data ?? [],
      runtime_server_key_type: adminKey.selectedType,
      policy_mode: "shadow_learning",
      production_auto_route: false,
      secret_values_returned: false,
      values_exposed: false,
    });
  }

  if (action === "command_ingest") {
    const objective = boundedString(body.objective, 1, 20_000);
    if (!objective) return fail("objective_required", 400);
    const tags = Array.isArray(body.tags)
      ? body.tags.filter((item): item is string => typeof item === "string").slice(0, 32)
      : [];
    const { data, error } = await admin.rpc("command_center_ingest", {
      p_user_id: user.id,
      p_source: boundedString(body.source, 1, 80) ?? "openclaw",
      p_objective: objective,
      p_source_ref: boundedString(body.source_ref, 1, 500),
      p_dedupe_key: boundedString(body.dedupe_key, 1, 200) ?? rawExecutionKey,
      p_context: safeJson(body.context, {}),
      p_constraints: safeJson(body.constraints, {}),
      p_acceptance_criteria: safeJson(body.acceptance_criteria, {}),
      p_task_type: boundedString(body.task_type, 1, 100) ?? "general",
      p_command_mode: boundedString(body.command_mode, 1, 20) ?? "standard",
      p_authority_scope: boundedString(body.authority_scope, 1, 30) ?? "observe",
      p_urgency: optionalNumber(body.urgency) ?? 50,
      p_impact: optionalNumber(body.impact) ?? 50,
      p_effort: optionalNumber(body.effort) ?? 50,
      p_risk_tier: optionalNumber(body.risk_tier) ?? 0,
      p_deadline_at: boundedString(body.deadline_at, 1, 64),
      p_tags: tags,
    });
    if (error || !data?.[0]) {
      console.error("command_ingest_failed", error?.code ?? "unknown");
      return fail("command_ingest_failed", 503);
    }
    return reply({ ok: true, admission, intent: data[0], values_exposed: false });
  }

  if (action === "decision_record") {
    const intentId = boundedString(body.intent_id, 36, 36);
    const selectedAction = boundedString(body.selected_action, 1, 160);
    const rationale = boundedString(body.rationale_summary, 1, 4000);
    if (!intentId || !UUID_RE.test(intentId) || !selectedAction || !rationale) {
      return fail("invalid_decision_payload", 400);
    }
    const { data, error } = await admin.rpc("command_center_record_decision", {
      p_user_id: user.id,
      p_intent_id: intentId,
      p_selected_action: selectedAction,
      p_rationale_summary: rationale,
      p_selected_route: boundedString(body.selected_route, 1, 160),
      p_decision_policy: boundedString(body.decision_policy, 1, 40) ?? "rule",
      p_candidate_actions: safeJson(body.candidate_actions, []),
      p_context_features: safeJson(body.context_features, {}),
      p_propensity: optionalNumber(body.propensity) ?? 1,
      p_confidence: optionalNumber(body.confidence),
      p_policy_snapshot: safeJson(body.policy_snapshot, {}),
      p_approval_state: boundedString(body.approval_state, 1, 30) ?? "not_required",
      p_decided_by: boundedString(body.decided_by, 1, 160) ?? "openclaw",
      p_intent_status: boundedString(body.intent_status, 1, 30) ?? "triaged",
    });
    if (error || !data?.[0]) {
      console.error("decision_record_failed", error?.code ?? "unknown");
      return fail("decision_record_failed", 503);
    }
    return reply({ ok: true, admission, decision: data[0], values_exposed: false });
  }

  if (action === "feedback_record") {
    const intentId = boundedString(body.intent_id, 36, 36);
    const outcome = boundedString(body.outcome, 1, 20);
    const reward = optionalNumber(body.reward);
    if (!intentId || !UUID_RE.test(intentId) || !outcome || reward === null) {
      return fail("invalid_feedback_payload", 400);
    }
    const decisionId = boundedString(body.decision_id, 36, 36);
    if (decisionId && !UUID_RE.test(decisionId)) {
      return fail("invalid_decision_id", 400);
    }
    const { data, error } = await admin.rpc("command_center_record_feedback", {
      p_user_id: user.id,
      p_intent_id: intentId,
      p_outcome: outcome,
      p_reward: reward,
      p_decision_id: decisionId,
      p_route_key: boundedString(body.route_key, 1, 160),
      p_action_key: boundedString(body.action_key, 1, 160),
      p_quality_score: optionalNumber(body.quality_score),
      p_friction_score: optionalNumber(body.friction_score),
      p_latency_ms: optionalNumber(body.latency_ms),
      p_user_effort_seconds: optionalNumber(body.user_effort_seconds),
      p_cost_krw: optionalNumber(body.cost_krw) ?? 0,
      p_duplicate_avoided: optionalBoolean(body.duplicate_avoided),
      p_rework_required: optionalBoolean(body.rework_required),
      p_evidence: safeJson(body.evidence, {}),
      p_reported_by: boundedString(body.reported_by, 1, 160) ?? "openclaw",
    });
    if (error || !data?.[0]) {
      console.error("feedback_record_failed", error?.code ?? "unknown");
      return fail("feedback_record_failed", 503);
    }
    return reply({ ok: true, admission, feedback: data[0], values_exposed: false });
  }

  const intentId = boundedString(body.intent_id, 36, 36);
  const objectType = boundedString(body.object_type, 1, 100);
  const objectKey = boundedString(body.object_key, 1, 500);
  if (!intentId || !UUID_RE.test(intentId) || !objectType || !objectKey) {
    return fail("invalid_object_link_payload", 400);
  }
  const { data, error } = await admin.rpc("command_center_link_object", {
    p_user_id: user.id,
    p_intent_id: intentId,
    p_object_type: objectType,
    p_object_key: objectKey,
    p_relation_type: boundedString(body.relation_type, 1, 100) ?? "relates_to",
    p_object_url: boundedString(body.object_url, 1, 2000),
    p_metadata: safeJson(body.metadata, {}),
    p_created_by: boundedString(body.created_by, 1, 160) ?? "openclaw",
  });
  if (error || !data?.[0]) {
    console.error("object_link_failed", error?.code ?? "unknown");
    return fail("object_link_failed", 503);
  }
  return reply({ ok: true, admission, link: data[0], values_exposed: false });
});
