import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";

function managedAdminKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (typeof keys?.default === "string" && keys.default.startsWith("sb_secret_")) return keys.default;
  } catch {
    // Compatibility fallback below.
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

function managedPublishableKey(): string | null {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}");
    return typeof keys?.default === "string" && keys.default.startsWith("sb_publishable_")
      ? keys.default
      : null;
  } catch {
    return null;
  }
}

const ADMIN_KEY = managedAdminKey();
const admin = createClient(SUPABASE_URL, ADMIN_KEY, {
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

async function requirePiUser(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw reply({ ok: false, error: "unauthorized" }, 401);
  const { data, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user) throw reply({ ok: false, error: "unauthorized" }, 401);
  if (data.user.app_metadata?.role !== "pi-gateway-client") {
    throw reply({ ok: false, error: "pi_identity_required" }, 403);
  }
  return data.user;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET" && req.method !== "POST") {
    return reply({ ok: false, error: "method_not_allowed" }, 405);
  }
  if (!SUPABASE_URL || !ADMIN_KEY) return reply({ ok: false, error: "server_not_configured" }, 503);

  let user;
  try {
    user = await requirePiUser(req);
  } catch (response) {
    if (response instanceof Response) return response;
    return reply({ ok: false, error: "authentication_failed" }, 401);
  }

  const publishableKey = managedPublishableKey();
  if (!publishableKey) return reply({ ok: false, error: "modern_publishable_key_unavailable" }, 503);

  const [controlsResult, configResult] = await Promise.all([
    admin.from("bridge_controls")
      .select("control_key,enabled")
      .in("control_key", [
        "supabase_modern_publishable_key",
        "supabase_legacy_anon_fallback",
        "vercel_connector_management",
        "vercel_raw_token_fallback",
        "paid_api_fallback",
        "telegram_single_poller_enforced",
      ]),
    admin.from("bridge_canonical_config")
      .select("config_key,config_value,enabled")
      .eq("enabled", true),
  ]);
  if (controlsResult.error || configResult.error) {
    return reply({ ok: false, error: "canonical_config_read_failed" }, 503);
  }

  const control = Object.fromEntries((controlsResult.data ?? []).map((row) => [row.control_key, row.enabled]));
  const config = Object.fromEntries((configResult.data ?? []).map((row) => [row.config_key, row.config_value]));
  if (control.supabase_modern_publishable_key !== true || control.supabase_legacy_anon_fallback !== false) {
    return reply({ ok: false, error: "canonical_supabase_policy_invalid" }, 503);
  }

  const project = config["supabase.project"] ?? {};
  const vercel = config["vercel.management"] ?? {};
  const zeroCostRoute = config["model.zero_cost_route"] ?? {};

  await admin.rpc("bridge_record_event", {
    p_event_type: "canonical_client_config_read",
    p_node_name: "raspberry-pi-5",
    p_correlation_id: req.headers.get("x-correlation-id"),
    p_severity: "info",
    p_outcome: "succeeded",
    p_detail: {
      actor_user_id: user.id,
      modern_publishable_key_selected: true,
      server_secret_returned: false,
      vercel_token_returned: false,
    },
  });

  return reply({
    ok: true,
    version: 2,
    supabase: {
      project_ref: project.project_ref ?? "dpllasnpfskyyyzebyal",
      url: project.url ?? SUPABASE_URL,
      region: project.region ?? "ap-southeast-1",
      publishable_key: publishableKey,
      publishable_key_name: "default",
      publishable_key_type: "modern",
      legacy_anon_fallback: false,
      endpoints: {
        emergency_bridge: `${SUPABASE_URL}/functions/v1/emergency-bridge`,
        credential_readiness: `${SUPABASE_URL}/functions/v1/credential-readiness`,
        pi_work_queue: `${SUPABASE_URL}/functions/v1/pi-work-queue`,
        token_gateway: `${SUPABASE_URL}/functions/v1/token-gateway`,
      },
    },
    vercel: {
      management_identity: vercel.identity ?? "connected_connector",
      team_id: vercel.team_id ?? "team_sa2sEffAlVXK6b9lsweDm6QL",
      team_slug: vercel.team_slug ?? "mnwersdfppap-5454s-projects",
      raw_token_fallback: false,
      selected_project: vercel.selected_project ?? null,
      deployment_enabled: vercel.deployment_enabled === true,
      reason: vercel.selected_project ? "selected_project_available" : "no_visible_project_selected",
    },
    routing: zeroCostRoute,
    policy: {
      paid_api_fallback: control.paid_api_fallback === true,
      public_shell_execution: false,
      telegram_single_poller_enforced: control.telegram_single_poller_enforced === true,
    },
    admin_key_source: (Deno.env.get("SUPABASE_SECRET_KEYS") ?? "").length > 0
      ? "modern_secret_default"
      : "legacy_service_role_compatibility",
    server_secret_returned: false,
    raw_vercel_token_returned: false,
  });
});
