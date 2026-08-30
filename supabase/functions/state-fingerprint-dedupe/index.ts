import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 32_768;
const MAX_PAYLOAD_BYTES = 24_576;
const MAX_PER_HOUR = 240;
const ALLOWED_ROLES = new Set(["pi-gateway-client", "pattern-observer"]);
const ALLOWED_PREFIXES = new Set([
  "openclaw",
  "pi",
  "telegram",
  "docker",
  "mcp",
  "n8n",
  "notion",
  "memory",
  "workflow",
  "system",
  "integration",
  "artifact",
  "credential",
]);
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
  if (SECRET_LIKE.test(raw)) {
    return reply(
      { ok: false, error: "secret_like_content_rejected", secret_values_included: false },
      400,
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
  const namespace = boundedString(body.namespace, 3, 160)?.toLowerCase() ?? null;
  const sourceRef = boundedString(body.source_ref, 1, 500);
  const payload = body.payload;

  if (!executionKey) {
    return reply(
      { ok: false, error: "execution_key_required", secret_values_included: false },
      400,
    );
  }
  if (!namespace || !/^[a-z0-9][a-z0-9._-]{2,159}$/.test(namespace)) {
    return reply(
      { ok: false, error: "namespace_invalid", secret_values_included: false },
      400,
    );
  }
  if (!ALLOWED_PREFIXES.has(namespace.split(".")[0])) {
    return reply(
      { ok: false, error: "namespace_prefix_not_allowed", secret_values_included: false },
      400,
    );
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return reply(
      { ok: false, error: "payload_object_required", secret_values_included: false },
      400,
    );
  }
  if (new TextEncoder().encode(JSON.stringify(payload)).byteLength > MAX_PAYLOAD_BYTES) {
    return reply(
      { ok: false, error: "state_payload_too_large", secret_values_included: false },
      413,
    );
  }

  const { data: existing } = await admin.from("bridge_request_ledger")
    .select("request_id")
    .eq("user_id", actor.user.id)
    .eq("action", "state_fingerprint_dedupe")
    .eq("execution_key", executionKey)
    .maybeSingle();
  if (existing) {
    return reply({
      ok: false,
      error: "duplicate_execution_key",
      duplicate_request: true,
      secret_values_included: false,
    }, 409);
  }

  const { count, error: countError } = await admin.from("bridge_request_ledger")
    .select("request_id", { count: "exact", head: true })
    .eq("user_id", actor.user.id)
    .eq("action", "state_fingerprint_dedupe")
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
      action: "state_fingerprint_dedupe",
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

  const { data, error } = await admin.rpc("bridge_upsert_state_fingerprint", {
    p_namespace: namespace,
    p_payload: payload,
    p_source_ref: sourceRef,
    p_normalizer_version: 1,
  });

  await admin.from("bridge_request_ledger").insert({
    user_id: actor.user.id,
    action: "state_fingerprint_dedupe",
    execution_key: executionKey,
    allowed: !error,
    duplicate: false,
    reason: error ? "state_fingerprint_write_failed" : "admitted",
  });

  if (error || !data || typeof data !== "object") {
    return reply(
      { ok: false, error: "state_fingerprint_write_failed", secret_values_included: false },
      500,
    );
  }

  const result = data as JsonRecord;
  await admin.from("bridge_events").insert({
    event_type: "state_fingerprint_recorded",
    node_name: namespace.split(".")[0],
    correlation_id: boundedString(body.correlation_id, 1, 128),
    severity: "info",
    outcome: "succeeded",
    detail: {
      actor_user_id: actor.user.id,
      actor_role: actor.role,
      namespace,
      fingerprint: result.fingerprint ?? null,
      duplicate: result.duplicate ?? null,
      seen_count: result.seen_count ?? null,
      exact_match_only: true,
      similar_items_auto_merged: false,
      canonical_payload_returned: false,
      secret_values_included: false,
    },
    created_at: new Date().toISOString(),
  });

  return reply({
    ok: true,
    namespace,
    fingerprint: result.fingerprint ?? null,
    duplicate: result.duplicate ?? false,
    seen_count: result.seen_count ?? null,
    source_ref_count: result.source_ref_count ?? null,
    normalizer_version: 1,
    exact_match_only: true,
    similar_items_auto_merged: false,
    canonical_payload_returned: false,
    secret_values_included: false,
  });
});
