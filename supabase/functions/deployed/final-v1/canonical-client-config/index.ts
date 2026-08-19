import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const PROJECT_REF = "dpllasnpfskyyyzebyal";
const VERCEL_TEAM_ID = "team_sa2sEffAlVXK6b9lsweDm6QL";
const VERCEL_TEAM_SLUG = "mnwersdfppap-5454s-projects";
const MAX_BODY_BYTES = 16_384;

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
  if (modern.default) return { value: modern.default, selectedType: "modern_secret_default", modernPresent: true, legacyPresent: Boolean(legacy) };
  const first = Object.values(modern)[0];
  if (typeof first === "string" && first.length > 0) {
    return { value: first, selectedType: "modern_secret_named", modernPresent: true, legacyPresent: Boolean(legacy) };
  }
  if (legacy) return { value: legacy, selectedType: "legacy_service_role_compatibility", modernPresent: false, legacyPresent: true };
  return { value: "", selectedType: "missing", modernPresent: false, legacyPresent: false };
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
  return reply({ ok: false, error: code, values_exposed: false, server_secret_returned: false }, status);
}

function boundedString(value: unknown, min: number, max: number): string | null {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result.length >= min && result.length <= max ? result : null;
}

async function requirePi(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw fail("unauthorized", 401);
  const { data, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user) throw fail("unauthorized", 401);
  if (data.user.app_metadata?.role !== "pi-gateway-client") throw fail("pi_identity_required", 403);
  return data.user;
}

async function parseBody(req: Request): Promise<JsonRecord> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) throw fail("payload_too_large", 413);
  try {
    const value = await req.json();
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("object required");
    return value as JsonRecord;
  } catch {
    throw fail("invalid_json", 400);
  }
}

async function validatePublishable(key: string): Promise<number | null> {
  if (!SUPABASE_URL || !key) return null;
  try {
    const response = await fetch(`${SUPABASE_URL}/auth/v1/settings`, {
      headers: { apikey: key, "user-agent": "openclaw-canonical-config/5" },
      signal: AbortSignal.timeout(10_000),
    });
    return response.status;
  } catch {
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey.value) return fail("server_not_configured", 503);
  if (!["GET", "POST"].includes(req.method)) return fail("method_not_allowed", 405);

  let user;
  try { user = await requirePi(req); }
  catch (response) { return response instanceof Response ? response : fail("authentication_failed", 401); }

  let body: JsonRecord = {};
  if (req.method === "POST") {
    try { body = await parseBody(req); }
    catch (response) { return response instanceof Response ? response : fail("invalid_request", 400); }
  }

  const executionKey = boundedString(body.execution_key ?? req.headers.get("x-execution-key"), 1, 128);
  const correlationId = boundedString(body.correlation_id ?? req.headers.get("x-correlation-id"), 1, 128);

  const { data: admissionRows, error: admissionError } = await admin.rpc("bridge_admit_request", {
    p_user_id: user.id, p_action: "canonical_config", p_execution_key: executionKey,
  });
  if (admissionError || !admissionRows?.[0]) return fail("admission_check_failed", 503);
  const admission = admissionRows[0];
  if (!admission.allowed) {
    return reply({ ok: false, error: admission.reason, admission, values_exposed: false, server_secret_returned: false },
      admission.reason === "rate_limit_exceeded" ? 429 : 403);
  }

  await admin.rpc("bridge_record_runtime_key_selection", {
    p_user_id: user.id, p_function_name: "canonical-client-config",
    p_selected_key_type: adminKey.selectedType,
    p_modern_key_present: adminKey.modernPresent,
    p_legacy_key_present: adminKey.legacyPresent,
    p_value_returned: false,
  });
  await admin.rpc("bridge_reconcile_runtime_key_unification");

  const { data: controls, error: controlsError } = await admin.from("bridge_controls")
    .select("control_key,enabled")
    .in("control_key", [
      "supabase_control_plane","supabase_modern_publishable_key","supabase_legacy_anon_fallback",
      "vercel_connector_management","vercel_raw_token_fallback","vercel_deployments",
      "paid_api_fallback","external_write_actions","public_shell_execution",
      "telegram_single_poller_enforced","modern_server_key_unification_verified",
    ]);
  if (controlsError) return fail("control_read_failed", 503);
  const switches = Object.fromEntries((controls ?? []).map((row) => [row.control_key, Boolean(row.enabled)]));
  if (switches.supabase_control_plane !== true || switches.supabase_modern_publishable_key !== true) {
    return fail("canonical_config_route_disabled", 503);
  }

  const publishableSet = parseNamedKeySet(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"));
  let publishableKey = publishableSet.default ?? "";
  let publishableName = "default";
  let publishableType = "publishable";
  if (!publishableKey) {
    const first = Object.entries(publishableSet)[0];
    if (first) { publishableName = first[0]; publishableKey = first[1]; }
  }
  if (!publishableKey && switches.supabase_legacy_anon_fallback === true) {
    publishableKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    publishableName = "legacy-anon-compatibility";
    publishableType = "legacy_anon";
  }
  if (!publishableKey) return fail("canonical_publishable_key_unavailable", 503);

  const validationStatus = await validatePublishable(publishableKey);
  if (validationStatus === null || validationStatus < 200 || validationStatus >= 300) {
    await admin.from("bridge_route_registry").update({
      health_status: "blocked", last_checked_at: new Date().toISOString(), updated_at: new Date().toISOString(),
    }).eq("route_key", "supabase.canonical_client_config");
    return reply({ ok: false, error: "canonical_publishable_key_validation_failed", validation_status: validationStatus,
      values_exposed: false, server_secret_returned: false,
      legacy_anon_fallback_enabled: Boolean(switches.supabase_legacy_anon_fallback) }, 503);
  }

  const { data: aliases, error: aliasError } = await admin.from("bridge_credential_alias_ssot")
    .select("alias_key,canonical_integration,source_scope,status,selected,configured,validation_status,read_only_default,last_validated_at,notes")
    .eq("selected", true).order("canonical_integration");
  if (aliasError) return fail("canonical_alias_read_failed", 503);

  const now = new Date().toISOString();
  await admin.from("bridge_route_registry").update({ health_status: "healthy", last_checked_at: now, updated_at: now })
    .eq("route_key", "supabase.canonical_client_config");
  await admin.from("bridge_credentials").update({
    configured: true, validation_status: "valid",
    validation_detail: "Canonical modern publishable key validated. No server secret returned.",
    last_validated_at: now,
    runtime_presence: { platform_managed: true, selected_key_name: publishableName, selected_key_type: publishableType },
    updated_at: now,
  }).eq("integration", "supabase_client");
  await admin.rpc("bridge_record_event", {
    p_event_type: "canonical_client_config_read", p_node_name: "raspberry-pi5",
    p_correlation_id: correlationId, p_severity: "info", p_outcome: "succeeded",
    p_detail: { actor_user_id: user.id, project_ref: PROJECT_REF,
      selected_publishable_name: publishableName, selected_publishable_type: publishableType,
      runtime_server_key_type: adminKey.selectedType, duplicate: Boolean(admission.duplicate),
      server_secret_returned: false },
  });

  return reply({
    ok: true, version: 5, admission,
    supabase: {
      project_ref: PROJECT_REF, url: SUPABASE_URL,
      publishable_key: publishableKey, publishable_key_name: publishableName,
      publishable_key_type: publishableType,
      legacy_anon_fallback_enabled: Boolean(switches.supabase_legacy_anon_fallback),
      functions: {
        canonical_client_config: `${SUPABASE_URL}/functions/v1/canonical-client-config`,
        credential_readiness: `${SUPABASE_URL}/functions/v1/credential-readiness`,
        emergency_bridge: `${SUPABASE_URL}/functions/v1/emergency-bridge`,
        command_center: `${SUPABASE_URL}/functions/v1/command-center`,
        pi_work_queue: `${SUPABASE_URL}/functions/v1/pi-work-queue`,
      },
    },
    vercel: {
      management_identity: switches.vercel_connector_management ? "connected_connector_session" : "disabled",
      team_id: VERCEL_TEAM_ID, team_slug: VERCEL_TEAM_SLUG,
      raw_token_fallback_enabled: Boolean(switches.vercel_raw_token_fallback),
      deployment_enabled: Boolean(switches.vercel_deployments),
      project_selection: "pending_visible_project",
    },
    policy: {
      paid_api_fallback: Boolean(switches.paid_api_fallback),
      external_write_actions: Boolean(switches.external_write_actions),
      public_shell_execution: Boolean(switches.public_shell_execution),
      telegram_single_poller_enforced: Boolean(switches.telegram_single_poller_enforced),
      modern_server_key_unification_verified: Boolean(switches.modern_server_key_unification_verified),
      server_secret_returned: false, oauth_token_returned: false, vercel_raw_token_returned: false,
    },
    selected_aliases: aliases ?? [], runtime_server_key_type: adminKey.selectedType,
    values_exposed: false, server_secret_returned: false, generated_at: now,
  });
});
