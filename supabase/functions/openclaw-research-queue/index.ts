import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 48 * 1024;
const MAX_SAFE_SUMMARY_BYTES = 32 * 1024;
const MAX_CLAIMS_PER_HOUR = 120;
const SECRET_LIKE = /(sk-proj-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{16,}|tskey-(?:auth|api|client)-[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._~+/-]{16,}|BEGIN\s+(?:RSA|OPENSSH|EC)\s+PRIVATE\s+KEY)/i;
const FORBIDDEN_KEYS = new Set([
  "command", "commands", "shell", "argv", "executable", "script",
  "source_code", "payload_code", "authorization", "access_token",
  "refresh_token", "api_key", "secret", "password", "private_key",
]);

type JsonRecord = Record<string, unknown>;
type KeyMap = Record<string, string>;
type ResearchTask = {
  research_id: string;
  candidate_id: string;
  provider: string;
  english_query: string;
  priority: number;
  state: string;
  attempts: number;
  max_attempts: number;
  not_before: string;
  lease_until: string | null;
  claimed_by: string | null;
};

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
    query_credentials_returned: false,
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

function isUuid(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function containsForbiddenKey(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(containsForbiddenKey);
  if (!value || typeof value !== "object") return false;
  for (const [key, item] of Object.entries(value as JsonRecord)) {
    if (FORBIDDEN_KEYS.has(key.toLowerCase())) return true;
    if (containsForbiddenKey(item)) return true;
  }
  return false;
}

function safeObject(value: unknown): JsonRecord | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const object = value as JsonRecord;
  const serialized = JSON.stringify(object);
  if (new TextEncoder().encode(serialized).byteLength > MAX_SAFE_SUMMARY_BYTES) return null;
  if (SECRET_LIKE.test(serialized) || containsForbiddenKey(object)) return null;
  return object;
}

async function parseBody(req: Request): Promise<JsonRecord | Response> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return fail("payload_too_large", 413);
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) return fail("payload_too_large", 413);
  if (SECRET_LIKE.test(raw)) return fail("secret_like_payload_rejected", 400);
  try {
    const value = JSON.parse(raw || "{}");
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
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

async function mutationRateAllowed(userId: string): Promise<boolean> {
  const since = new Date(Date.now() - 3_600_000).toISOString();
  const { count, error } = await admin
    .from("bridge_events")
    .select("event_id", { count: "exact", head: true })
    .eq("node_name", `research:${userId}`)
    .in("event_type", [
      "research_task_claimed", "research_task_completed",
      "research_task_failed", "research_task_lease_extended",
    ])
    .gte("created_at", since);
  return !error && (count ?? 0) < MAX_CLAIMS_PER_HOUR;
}

async function taskForOwner(researchId: string, owner: string): Promise<ResearchTask | null> {
  const { data, error } = await admin
    .from("bridge_research_queue")
    .select("research_id,candidate_id,provider,english_query,priority,state,attempts,max_attempts,not_before,lease_until,claimed_by")
    .eq("research_id", researchId)
    .maybeSingle();
  if (error || !data || data.claimed_by !== owner) return null;
  return data as ResearchTask;
}

async function recordEvent(
  eventType: string,
  userId: string,
  outcome: string,
  detail: JsonRecord,
): Promise<void> {
  await admin.from("bridge_events").insert({
    event_type: eventType,
    node_name: `research:${userId}`,
    correlation_id: crypto.randomUUID(),
    severity: outcome === "succeeded" ? "info" : "warning",
    outcome,
    detail: {
      ...detail,
      query_credentials_returned: false,
      provider_secret_returned: false,
      server_secret_returned: false,
      arbitrary_execution_allowed: false,
      secret_values_included: false,
    },
    created_at: new Date().toISOString(),
  });
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
  const owner = `research:${user.id}`;

  if (action === "status") {
    const { data, error } = await admin
      .from("bridge_research_queue")
      .select("state,provider,attempts,max_attempts,not_before,lease_until")
      .limit(5000);
    if (error) return fail("research_status_read_failed", 503);
    const rows = data ?? [];
    const states: Record<string, number> = {};
    const providers: Record<string, number> = {};
    for (const row of rows) {
      states[row.state] = (states[row.state] ?? 0) + 1;
      providers[row.provider] = (providers[row.provider] ?? 0) + 1;
    }
    return reply({
      ok: true,
      states,
      providers,
      due_queued: rows.filter((row) => row.state === "queued" && new Date(row.not_before).getTime() <= Date.now()).length,
      query_credentials_returned: false,
      provider_secret_returned: false,
      server_secret_returned: false,
      arbitrary_execution_allowed: false,
      secret_values_included: false,
    });
  }

  if (!await mutationRateAllowed(user.id)) return fail("rate_limit_exceeded", 429);

  if (action === "claim") {
    const leaseMinutesRaw = Number(body.lease_minutes ?? 15);
    const leaseMinutes = Number.isFinite(leaseMinutesRaw)
      ? Math.max(1, Math.min(Math.trunc(leaseMinutesRaw), 60))
      : 15;
    const { data, error } = await admin.rpc("bridge_claim_research_task", {
      p_worker: owner,
      p_lease_minutes: leaseMinutes,
    });
    if (error) return fail("research_claim_failed", 503);
    const task = Array.isArray(data) && data[0] ? data[0] as ResearchTask : null;
    if (!task) {
      return reply({
        ok: true,
        no_work: true,
        task: null,
        query_credentials_returned: false,
        provider_secret_returned: false,
        server_secret_returned: false,
        arbitrary_execution_allowed: false,
        secret_values_included: false,
      });
    }
    const { data: candidate } = await admin
      .from("bridge_pattern_candidates")
      .select("fingerprint,canonical_title,priority_score,state")
      .eq("candidate_id", task.candidate_id)
      .maybeSingle();
    await recordEvent("research_task_claimed", user.id, "succeeded", {
      research_id: task.research_id,
      provider: task.provider,
      candidate_id: task.candidate_id,
      lease_minutes: leaseMinutes,
    });
    return reply({
      ok: true,
      no_work: false,
      task: {
        research_id: task.research_id,
        candidate_id: task.candidate_id,
        fingerprint: candidate?.fingerprint ?? null,
        canonical_title: candidate?.canonical_title ?? null,
        candidate_state: candidate?.state ?? null,
        provider: task.provider,
        english_query: task.english_query,
        priority: task.priority,
        attempts: task.attempts,
        max_attempts: task.max_attempts,
        lease_until: task.lease_until,
        output_contract: {
          result_ref: "official URL or connector reference",
          result_count: "0..1000",
          result_summary: "bounded non-secret JSON object",
        },
      },
      query_credentials_returned: false,
      provider_secret_returned: false,
      server_secret_returned: false,
      arbitrary_execution_allowed: false,
      secret_values_included: false,
    });
  }

  const researchId = body.research_id;
  if (!isUuid(researchId)) return fail("valid_research_id_required", 400);
  const task = await taskForOwner(researchId, owner);
  if (!task) return fail("claimed_research_task_required", 409);

  if (action === "heartbeat") {
    if (task.state !== "claimed") return fail("research_task_not_claimed", 409);
    const extendRaw = Number(body.extend_minutes ?? 10);
    const extendMinutes = Number.isFinite(extendRaw)
      ? Math.max(1, Math.min(Math.trunc(extendRaw), 30))
      : 10;
    const leaseUntil = new Date(Date.now() + extendMinutes * 60_000).toISOString();
    const { error } = await admin.from("bridge_research_queue").update({
      lease_until: leaseUntil,
      updated_at: new Date().toISOString(),
    }).eq("research_id", researchId).eq("state", "claimed").eq("claimed_by", owner);
    if (error) return fail("lease_extension_failed", 503);
    await recordEvent("research_task_lease_extended", user.id, "succeeded", {
      research_id: researchId,
      extend_minutes: extendMinutes,
    });
    return reply({
      ok: true,
      research_id: researchId,
      lease_until: leaseUntil,
      query_credentials_returned: false,
      provider_secret_returned: false,
      server_secret_returned: false,
      arbitrary_execution_allowed: false,
      secret_values_included: false,
    });
  }

  if (action === "complete") {
    if (task.state === "completed") {
      return reply({
        ok: true,
        already_completed: true,
        research_id: researchId,
        secret_values_included: false,
      });
    }
    if (task.state !== "claimed") return fail("research_task_not_claimed", 409);
    const resultRef = bounded(body.result_ref, 3, 1000);
    const resultSummary = safeObject(body.result_summary ?? {});
    const resultCountRaw = Number(body.result_count ?? 0);
    const resultCount = Number.isFinite(resultCountRaw)
      ? Math.max(0, Math.min(Math.trunc(resultCountRaw), 1000))
      : 0;
    if (!resultRef || !resultSummary) return fail("safe_result_contract_required", 400);
    if (SECRET_LIKE.test(resultRef)) return fail("secret_like_result_ref_rejected", 400);

    const completedAt = new Date().toISOString();
    const { error } = await admin.from("bridge_research_queue").update({
      state: "completed",
      result_ref: resultRef,
      result_summary: {
        ...resultSummary,
        reviewed: false,
        provider: task.provider,
        secret_values_included: false,
      },
      result_count: resultCount,
      lease_until: null,
      claimed_by: null,
      last_error: null,
      completed_at: completedAt,
      updated_at: completedAt,
    }).eq("research_id", researchId).eq("state", "claimed").eq("claimed_by", owner);
    if (error) return fail("research_completion_failed", 503);

    if (resultCount > 0) {
      await admin.from("bridge_pattern_candidates").update({
        state: "solution_found",
        updated_at: completedAt,
      }).eq("candidate_id", task.candidate_id).in("state", ["researching", "ready_for_research"]);
    }
    await recordEvent("research_task_completed", user.id, "succeeded", {
      research_id: researchId,
      candidate_id: task.candidate_id,
      provider: task.provider,
      result_count: resultCount,
      result_ref: resultRef.slice(0, 500),
      result_reviewed: false,
    });
    return reply({
      ok: true,
      research_id: researchId,
      state: "completed",
      result_count: resultCount,
      candidate_state: resultCount > 0 ? "solution_found" : "unchanged",
      result_requires_review: true,
      query_credentials_returned: false,
      provider_secret_returned: false,
      server_secret_returned: false,
      arbitrary_execution_allowed: false,
      secret_values_included: false,
    });
  }

  if (action === "fail") {
    if (task.state !== "claimed") return fail("research_task_not_claimed", 409);
    const errorCode = bounded(body.error_code, 3, 160) ?? "research_worker_failed";
    if (SECRET_LIKE.test(errorCode)) return fail("unsafe_error_code_rejected", 400);
    const terminal = task.attempts >= task.max_attempts;
    const delays = [120, 300, 900, 2700, 7200];
    const delay = delays[Math.min(Math.max(task.attempts - 1, 0), delays.length - 1)];
    const { error } = await admin.from("bridge_research_queue").update({
      state: terminal ? "failed" : "queued",
      not_before: terminal ? task.not_before : new Date(Date.now() + delay * 1000).toISOString(),
      lease_until: null,
      claimed_by: null,
      last_error: errorCode,
      updated_at: new Date().toISOString(),
      completed_at: terminal ? new Date().toISOString() : null,
    }).eq("research_id", researchId).eq("state", "claimed").eq("claimed_by", owner);
    if (error) return fail("research_failure_update_failed", 503);
    await recordEvent("research_task_failed", user.id, terminal ? "failed" : "succeeded", {
      research_id: researchId,
      candidate_id: task.candidate_id,
      provider: task.provider,
      terminal,
      retry_after_seconds: terminal ? null : delay,
      error_code: errorCode,
    });
    return reply({
      ok: true,
      research_id: researchId,
      state: terminal ? "failed" : "queued",
      retry_after_seconds: terminal ? null : delay,
      query_credentials_returned: false,
      provider_secret_returned: false,
      server_secret_returned: false,
      arbitrary_execution_allowed: false,
      secret_values_included: false,
    });
  }

  return fail("unsupported_action", 400);
});
