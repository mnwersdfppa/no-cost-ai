import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const LEGACY_SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

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
const selectedPublishable = publishableKeys.default ?? "";
const admin = createClient(SUPABASE_URL, adminKey, {
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

async function requirePi(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) {
    throw reply({ ok: false, error: "unauthorized", values_exposed: false }, 401);
  }
  const { data, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user) {
    throw reply({ ok: false, error: "unauthorized", values_exposed: false }, 401);
  }
  if (data.user.app_metadata?.role !== "pi-gateway-client") {
    throw reply({ ok: false, error: "pi_identity_required", values_exposed: false }, 403);
  }
  return data.user;
}

async function validatePublishableKey(): Promise<{ valid: boolean; status: number | null }> {
  if (!SUPABASE_URL || !selectedPublishable) return { valid: false, status: null };
  try {
    const response = await fetch(`${SUPABASE_URL}/auth/v1/settings`, {
      headers: {
        apikey: selectedPublishable,
        "user-agent": "openclaw-canonical-config/2",
      },
      signal: AbortSignal.timeout(10_000),
    });
    return { valid: response.ok, status: response.status };
  } catch {
    return { valid: false, status: null };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET" && req.method !== "POST") {
    return reply({ ok: false, error: "method_not_allowed", values_exposed: false }, 405);
  }
  if (!SUPABASE_URL || !adminKey || !selectedPublishable) {
    return reply({
      ok: false,
      error: "modern_publishable_key_required",
      legacy_anon_fallback_enabled: false,
      values_exposed: false,
    }, 503);
  }

  let user;
  try {
    user = await requirePi(req);
  } catch (response) {
    if (response instanceof Response) return response;
    return reply({ ok: false, error: "authentication_failed", values_exposed: false }, 401);
  }

  const validation = await validatePublishableKey();
  const now = new Date().toISOString();
  await admin.from("bridge_credentials").update({
    configured: validation.valid,
    validation_status: validation.valid ? "valid" : "blocked",
    validation_detail: validation.valid
      ? "Canonical modern publishable client key validated against the Supabase Auth settings endpoint. No server secret returned."
      : `Canonical modern publishable key validation failed with status ${validation.status ?? "network_error"}. Legacy anon fallback remains disabled.`,
    runtime_presence: {
      platform_managed: true,
      selected_key_name: "default",
      selected_key_type: "publishable",
    },
    last_validated_at: now,
    updated_at: now,
  }).eq("integration", "supabase_client");

  await admin.from("bridge_route_registry").update({
    health_status: validation.valid ? "healthy" : "blocked",
    last_checked_at: now,
    updated_at: now,
  }).eq("route_key", "supabase.canonical_client_config");

  await admin.rpc("bridge_record_event", {
    p_event_type: "canonical_client_config_read",
    p_node_name: null,
    p_correlation_id: req.headers.get("x-correlation-id"),
    p_severity: validation.valid ? "info" : "warning",
    p_outcome: validation.valid ? "succeeded" : "blocked",
    p_detail: {
      user_id: user.id,
      selected_key_type: "publishable",
      key_validation_status: validation.status,
      legacy_anon_fallback_enabled: false,
      secret_values_returned: false,
    },
  });

  if (!validation.valid) {
    return reply({
      ok: false,
      error: "canonical_publishable_key_validation_failed",
      validation,
      legacy_anon_fallback_enabled: false,
      values_exposed: false,
    }, 503);
  }

  return reply({
    ok: true,
    config_version: 2,
    supabase: {
      project_ref: "dpllasnpfskyyyzebyal",
      url: SUPABASE_URL,
      publishable_key_name: "default",
      publishable_key_type: "publishable",
      publishable_key: selectedPublishable,
      legacy_anon_fallback_enabled: false,
      server_secret_returned: false,
    },
    vercel: {
      canonical_auth_mode: "connected_connector",
      team_id: "team_sa2sEffAlVXK6b9lsweDm6QL",
      team_slug: "mnwersdfppap-5454s-projects",
      visible_project_count: 0,
      raw_token_fallback_enabled: false,
      deploy_enabled: false,
    },
    policy: {
      paid_api_fallback: false,
      external_write_actions: false,
      public_shell_execution: false,
      telegram_single_poller_enforced: true,
      raw_secret_values_returned: false,
      intended_consumer: "pi-gateway-client",
    },
  });
});
