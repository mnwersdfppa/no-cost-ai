import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const PROJECT_REF = "dpllasnpfskyyyzebyal";
const VERCEL_TEAM_ID = "team_sa2sEffAlVXK6b9lsweDm6QL";
const VERCEL_TEAM_SLUG = "mnwersdfppap-5454s-projects";

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

function resolveAdminKey(): { value: string; source: string } {
  const modern = parseNamedKeySet(Deno.env.get("SUPABASE_SECRET_KEYS"));
  if (modern.default) return { value: modern.default, source: "SUPABASE_SECRET_KEYS.default" };
  const first = Object.entries(modern)[0];
  if (first) return { value: first[1], source: `SUPABASE_SECRET_KEYS.${first[0]}` };
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  return { value: legacy, source: legacy ? "SUPABASE_SERVICE_ROLE_KEY.compatibility" : "missing" };
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

async function requirePi(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw reply({ ok: false, error: "unauthorized", server_secret_returned: false }, 401);
  const { data, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user) throw reply({ ok: false, error: "unauthorized", server_secret_returned: false }, 401);
  if (data.user.app_metadata?.role !== "pi-gateway-client") throw reply({ ok: false, error: "pi_identity_required", server_secret_returned: false }, 403);
  return data.user;
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey.value) return reply({ ok: false, error: "server_not_configured", server_secret_returned: false }, 503);
  if (!["GET", "POST"].includes(req.method)) return reply({ ok: false, error: "method_not_allowed", server_secret_returned: false }, 405);

  let user;
  try {
    user = await requirePi(req);
  } catch (response) {
    if (response instanceof Response) return response;
    return reply({ ok: false, error: "authentication_failed", server_secret_returned: false }, 401);
  }

  const { data: controls, error: controlsError } = await admin
    .from("bridge_controls")
    .select("control_key,enabled")
    .in("control_key", [
      "supabase_modern_publishable_key",
      "supabase_legacy_anon_fallback",
      "vercel_connector_management",
      "vercel_raw_token_fallback",
      "paid_api_fallback",
      "telegram_single_poller_enforced",
    ]);
  if (controlsError) return reply({ ok: false, error: "control_read_failed", server_secret_returned: false }, 503);

  const switches = Object.fromEntries((controls ?? []).map((row) => [row.control_key, Boolean(row.enabled)]));
  const modernPublishable = parseNamedKeySet(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"));
  let selectedName = "default";
  let selectedType = "publishable";
  let publishableKey = modernPublishable.default ?? "";

  if (!publishableKey) {
    const first = Object.entries(modernPublishable)[0];
    if (first) {
      selectedName = first[0];
      publishableKey = first[1];
    }
  }

  if (!publishableKey && switches.supabase_legacy_anon_fallback) {
    publishableKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    selectedName = "legacy-anon-compatibility";
    selectedType = "legacy_anon";
  }

  if (!publishableKey) {
    return reply({
      ok: false,
      error: "canonical_publishable_key_unavailable",
      legacy_fallback_enabled: Boolean(switches.supabase_legacy_anon_fallback),
      server_secret_returned: false,
    }, 503);
  }

  const { data: aliases } = await admin
    .from("bridge_credential_aliases")
    .select("integration,alias_name,alias_kind,source_scope,validation_status,last_checked_at")
    .eq("selected", true)
    .order("integration");

  await admin.rpc("bridge_record_event", {
    p_event_type: "canonical_client_config_read",
    p_node_name: "raspberry-pi-5",
    p_correlation_id: req.headers.get("x-correlation-id"),
    p_severity: "info",
    p_outcome: "succeeded",
    p_detail: {
      actor_user_id: user.id,
      project_ref: PROJECT_REF,
      selected_publishable_name: selectedName,
      selected_publishable_type: selectedType,
      server_secret_returned: false,
    },
  });

  return reply({
    ok: true,
    version: 2,
    supabase: {
      project_ref: PROJECT_REF,
      url: SUPABASE_URL,
      publishable_key: publishableKey,
      publishable_key_name: selectedName,
      publishable_key_type: selectedType,
      legacy_anon_fallback_enabled: Boolean(switches.supabase_legacy_anon_fallback),
      functions: {
        canonical_client_config: `${SUPABASE_URL}/functions/v1/canonical-client-config`,
        credential_readiness: `${SUPABASE_URL}/functions/v1/credential-readiness`,
        emergency_bridge: `${SUPABASE_URL}/functions/v1/emergency-bridge`,
        pi_work_queue: `${SUPABASE_URL}/functions/v1/pi-work-queue`,
      },
    },
    vercel: {
      management_identity: switches.vercel_connector_management ? "connected_connector_session" : "disabled",
      team_id: VERCEL_TEAM_ID,
      team_slug: VERCEL_TEAM_SLUG,
      raw_token_fallback_enabled: Boolean(switches.vercel_raw_token_fallback),
      deployment_enabled: false,
      project_selection: "pending_visible_project",
    },
    policy: {
      paid_api_fallback: Boolean(switches.paid_api_fallback),
      telegram_single_poller_enforced: Boolean(switches.telegram_single_poller_enforced),
      server_secret_returned: false,
      oauth_token_returned: false,
      vercel_raw_token_returned: false,
    },
    selected_aliases: aliases ?? [],
    admin_key_source_internal_only: adminKey.source.startsWith("SUPABASE_SECRET_KEYS")
      ? "managed_modern_secret_keys"
      : "managed_legacy_compatibility",
    generated_at: new Date().toISOString(),
  });
});
