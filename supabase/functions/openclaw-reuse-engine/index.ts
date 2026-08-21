import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 16 * 1024;
const SECRET_LIKE = /(sk-proj-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{16,}|tskey-(?:auth|api|client)-[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._~+/-]{16,}|BEGIN\s+(?:RSA|OPENSSH|EC)\s+PRIVATE\s+KEY)/i;
const ACTIONS = new Set(["status", "sources", "reuse_queue", "research_queries", "projection_status"]);

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
const adminKey = secretSet.default
  ?? Object.values(secretSet)[0]
  ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  ?? "";
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
    read_only: true,
    promotion_exposed: false,
    claim_exposed: false,
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

async function authenticate(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7).trim();
  if (token.length < 20 || token.length > 8192) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user || data.user.app_metadata?.role !== "pi-gateway-client") return null;
  return data.user;
}

async function parseBody(req: Request): Promise<JsonRecord | Response> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    return fail("payload_too_large", 413);
  }
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    return fail("payload_too_large", 413);
  }
  if (SECRET_LIKE.test(raw)) return fail("secret_like_payload_rejected", 400);
  try {
    const value = JSON.parse(raw || "{}");
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value as JsonRecord;
  } catch {
    return fail("invalid_json", 400);
  }
}

function limitOf(value: unknown, fallback = 20, maximum = 100): number {
  const number = Number(value);
  return Number.isFinite(number)
    ? Math.max(1, Math.min(Math.trunc(number), maximum))
    : fallback;
}

function safeEnvelope(body: JsonRecord): JsonRecord {
  return {
    ok: true,
    engine_version: 1,
    read_only: true,
    promotion_exposed: false,
    claim_exposed: false,
    ...body,
    values_exposed: false,
    provider_secret_returned: false,
    server_secret_returned: false,
    arbitrary_execution_allowed: false,
    secret_values_included: false,
  };
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
  if (!ACTIONS.has(action)) return fail("unsupported_action", 400);

  if (action === "status") {
    const [sources, matches, research, projections, patterns] = await Promise.all([
      admin.from("openclaw_solution_sources")
        .select("source_key", { count: "exact", head: true })
        .eq("enabled", true),
      admin.from("openclaw_pattern_source_matches")
        .select("source_key", { count: "exact", head: true }),
      admin.from("openclaw_research_queries").select("query_id,status"),
      admin.from("openclaw_ssot_projection_queue")
        .select("projection_id,status,target_system"),
      admin.from("openclaw_pattern_candidates")
        .select("pattern_key", { count: "exact", head: true }),
    ]);
    if (sources.error || matches.error || research.error || projections.error || patterns.error) {
      return fail("reuse_status_read_failed", 503);
    }
    const researchCounts: Record<string, number> = {};
    for (const row of research.data ?? []) {
      researchCounts[row.status] = (researchCounts[row.status] ?? 0) + 1;
    }
    const projectionCounts: Record<string, number> = {};
    for (const row of projections.data ?? []) {
      const key = `${row.target_system}:${row.status}`;
      projectionCounts[key] = (projectionCounts[key] ?? 0) + 1;
    }
    return reply(safeEnvelope({
      counts: {
        patterns: patterns.count ?? 0,
        enabled_sources: sources.count ?? 0,
        source_matches: matches.count ?? 0,
        research: researchCounts,
        projections: projectionCounts,
      },
      policy: {
        official_sources_first: true,
        license_required: true,
        api_or_mcp_before_llm: true,
        docker_for_portable_validation: true,
        host_adapter_for_privileged_actions: true,
        covert_or_unauthorized_sources: false,
        automatic_merge: false,
      },
    }));
  }

  if (action === "sources") {
    const limit = limitOf(body.limit, 30, 100);
    const sourceClass = bounded(body.source_class, 2, 40);
    const trustTier = bounded(body.trust_tier, 2, 40);
    const adoptionState = bounded(body.adoption_state, 2, 40);
    let query = admin.from("openclaw_solution_sources")
      .select("source_key,name,source_class,repository_url,docs_url,license_name,license_class,trust_tier,capabilities,workload_tags,deployment_modes,supported_platforms,resource_profile,integration_contract,selection_policy,risk_notes,adoption_state,last_verified_at")
      .eq("enabled", true)
      .order("adoption_state", { ascending: true })
      .order("trust_tier", { ascending: true })
      .order("source_key", { ascending: true })
      .limit(limit);
    if (sourceClass) query = query.eq("source_class", sourceClass);
    if (trustTier) query = query.eq("trust_tier", trustTier);
    if (adoptionState) query = query.eq("adoption_state", adoptionState);
    const { data, error } = await query;
    if (error) return fail("source_catalog_read_failed", 503);
    return reply(safeEnvelope({ sources: data ?? [] }));
  }

  if (action === "reuse_queue") {
    const limit = limitOf(body.limit, 20, 100);
    const patternKey = bounded(body.pattern_key, 3, 120);
    let query = admin.from("openclaw_reuse_first_queue")
      .select("pattern_key,title_ko,title_en,category,pattern_status,risk_level,promotion_score,automation_target,source_key,source_name,source_class,license_name,adoption_state,match_score,reuse_role,match_status,rationale_ko,integration_plan,next_action")
      .order("promotion_score", { ascending: false })
      .order("pattern_key", { ascending: true })
      .limit(limit);
    if (patternKey) query = query.eq("pattern_key", patternKey);
    const { data, error } = await query;
    if (error) return fail("reuse_queue_read_failed", 503);
    return reply(safeEnvelope({ reuse_queue: data ?? [] }));
  }

  if (action === "research_queries") {
    const limit = limitOf(body.limit, 20, 100);
    const status = bounded(body.status, 3, 40);
    const patternKey = bounded(body.pattern_key, 3, 120);
    let query = admin.from("openclaw_research_queries")
      .select("query_id,pattern_key,query_en,source_scope,priority,status,attempts,max_attempts,not_before,completed_at,created_at,updated_at")
      .order("priority", { ascending: false })
      .order("query_id", { ascending: true })
      .limit(limit);
    if (status) query = query.eq("status", status);
    if (patternKey) query = query.eq("pattern_key", patternKey);
    const { data, error } = await query;
    if (error) return fail("research_queries_read_failed", 503);
    return reply(safeEnvelope({ research_queries: data ?? [] }));
  }

  const { data, error } = await admin.from("openclaw_ssot_projection_queue")
    .select("target_system,status,attempts,max_attempts,not_before,projected_at,created_at,updated_at");
  if (error) return fail("projection_status_read_failed", 503);
  const counts: Record<string, number> = {};
  for (const row of data ?? []) {
    const key = `${row.target_system}:${row.status}`;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return reply(safeEnvelope({ projection_status: { counts, rows: data ?? [] } }));
});
