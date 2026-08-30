import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const LEGACY_SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PROJECT_REF = "dpllasnpfskyyyzebyal";
const VERCEL_TEAM_ID = "team_sa2sEffAlVXK6b9lsweDm6QL";
const VERCEL_TEAM_SLUG = "mnwersdfppap-5454s-projects";

function parseDictionary(name: string): Record<string, string> {
  const raw = Deno.env.get(name);
  if (!raw) return {};
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter((entry): entry is [string, string] =>
        typeof entry[1] === "string" && entry[1].length > 0
      ),
    );
  } catch {
    return {};
  }
}

const publishableKeys = parseDictionary("SUPABASE_PUBLISHABLE_KEYS");
const secretKeys = parseDictionary("SUPABASE_SECRET_KEYS");
const adminKey = secretKeys.default ?? LEGACY_SERVICE_ROLE;
const admin = createClient(SUPABASE_URL, adminKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function reply(body: unknown, status = 200) {
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

function boundedString(value: unknown, min: number, max: number): string | null {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result.length >= min && result.length <= max ? result : null;
}

async function requirePi(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) {
    throw reply({ ok: false, error: "unauthorized", server_secret_returned: false }, 401);
  }
  const { data, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user) {
    throw reply({ ok: false, error: "unauthorized", server_secret_returned: false }, 401);
  }
  if (data.user.app_metadata?.role !== "pi-gateway-client") {
    throw reply({ ok: false, error: "pi_identity_required", server_secret_returned: false }, 403);
  }
  return data.user;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return reply({ ok: false, error: "method_not_allowed", server_secret_returned: false }, 405);
  }
  if (!SUPABASE_URL || !adminKey) {
    return reply({ ok: false, error: "server_not_configured", server_secret_returned: false }, 503);
  }

  let user;
  try {
    user = await requirePi(req);
  } catch (response) {
    if (response instanceof Response) return response;
    return reply({ ok: false, error: "authentication_failed", server_secret_returned: false }, 401);
  }

  let body: Record<string, unknown> = {};
  try {
    const parsed = await req.json();
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) body = parsed as Record<string, unknown>;
  } catch {
    body = {};
  }

  const executionKey = boundedString(body.execution_key ?? req.headers.get("x-execution-key"), 1, 128);
  const correlationId = boundedString(body.correlation_id ?? req.headers.get("x-correlation-id"), 1, 128);

  const { data: admissions, error: admissionError } = await admin.rpc("bridge_admit_request", {
    p_user_id: user.id,
    p_action: "canonical_client_config",
    p_execution_key: executionKey,
  });
  if (admissionError || !admissions?.[0]) {
    return reply({ ok: false, error: "admission_check_failed", server_secret_returned: false }, 503);
  }
  const admission = admissions[0];
  if (!admission.allowed) {
    return reply({
      ok: false,
      error: admission.reason,
      admission,
      server_secret_returned: false,
      raw_vercel_token_returned: false,
    }, admission.reason === "rate_limit_exceeded" ? 429 : 403);
  }

  const publishableKey = publishableKeys.default ?? "";
  if (!publishableKey) {
    return reply({
      ok: false,
      error: "modern_publishable_key_required",
      admission,
      legacy_anon_fallback_enabled: false,
      server_secret_returned: false,
      raw_vercel_token_returned: false,
    }, 503);
  }

  await admin.rpc("bridge_record_event", {
    p_event_type: "canonical_client_config",
    p_node_name: null,
    p_correlation_id: correlationId,
    p_severity: "info",
    p_outcome: "succeeded",
    p_detail: {
      actor_user_id: user.id,
      key_alias: "default",
      server_secret_returned: false,
      raw_vercel_token_returned: false,
    },
  });

  return reply({
    ok: true,
    duplicate: Boolean(admission.duplicate),
    admission,
    supabase: {
      project_ref: PROJECT_REF,
      project_url: SUPABASE_URL,
      publishable_key_alias: "default",
      publishable_key: publishableKey,
      legacy_anon_fallback_enabled: false,
      server_key_location: "edge_runtime_only",
      server_secret_returned: false,
    },
    vercel: {
      management_identity: "connected_connector",
      team_id: VERCEL_TEAM_ID,
      team_slug: VERCEL_TEAM_SLUG,
      project_id: null,
      deploy_enabled: false,
      raw_token_fallback_enabled: false,
      raw_vercel_token_returned: false,
    },
    policy: {
      paid_api_fallback: false,
      external_write_actions: false,
      phone_write_actions: false,
      public_shell_execution: false,
      telegram_single_poller_enforced: true,
    },
    server_secret_returned: false,
    raw_vercel_token_returned: false,
    oauth_token_returned: false,
  });
});
