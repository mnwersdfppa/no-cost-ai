import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const OPENCODE_ALIAS = "Opencode-api-key";
const TAILSCALE_ALIAS = "Tailscale-fff-api-key";
const MAX_BODY_BYTES = 16_384;
const MAX_BOOTSTRAPS_PER_HOUR = 3;
const DEFAULT_GATEWAY = `${SUPABASE_URL}/functions/v1/pi-model-gateway-guardian/v1`;
const DISCOVERABLE_FREE_MODELS = [
  "nemotron-3-ultra-free",
  "laguna-s-2.1-free",
  "deepseek-v4-flash-free",
  "mimo-v2.5-free",
  "big-pickle",
] as const;

type JsonRecord = Record<string, unknown>;
type Session = {
  user: { id: string; app_metadata?: Record<string, unknown> };
  accessToken: string;
  refreshToken: string | null;
  expiresIn: number | null;
  refreshed: boolean;
};
type CanonicalRoute = {
  baseUrl: string;
  primaryId: string | null;
  fallbackIds: string[];
  utilityId: string | null;
  quarantinedIds: string[];
  failurePolicy: JsonRecord;
};

function parseNamed(raw: string | undefined): Record<string, string> {
  if (!raw) return {};
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter(([, v]) => typeof v === "string" && v.length > 0),
    ) as Record<string, string>;
  } catch {
    return {};
  }
}

function resolveAdmin(): { value: string; type: string } {
  const modern = parseNamed(Deno.env.get("SUPABASE_SECRET_KEYS"));
  if (modern.default) return { value: modern.default, type: "modern_secret_default" };
  const first = Object.values(modern)[0];
  if (first) return { value: first, type: "modern_secret_named" };
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  return legacy
    ? { value: legacy, type: "legacy_service_role_compatibility" }
    : { value: "", type: "missing" };
}

function resolvePublishable(): string {
  const modern = parseNamed(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"));
  if (modern.default) return modern.default;
  const first = Object.values(modern)[0];
  if (first) return first;
  return Deno.env.get("SUPABASE_ANON_KEY") ?? "";
}

const adminKey = resolveAdmin();
const publishableKey = resolvePublishable();
const admin = createClient(SUPABASE_URL, adminKey.value, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function reply(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
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
    destination: "authenticated_pi_only",
    provider_secret_returned: false,
    tailscale_auth_key_returned: false,
    values_logged: false,
    secret_values_included: false,
  }, status);
}

function bounded(value: unknown, min: number, max: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text.length >= min && text.length <= max ? text : null;
}

function providerId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const ref = value.trim();
  if (!ref) return null;
  for (const prefix of ["supabase-opencode/", "opencode/"]) {
    if (ref.startsWith(prefix)) return ref.slice(prefix.length);
  }
  return ref;
}

function unique(values: string[]): string[] {
  return [...new Set(values.filter(Boolean))];
}

function safeGateway(value: unknown): string {
  if (typeof value !== "string") return DEFAULT_GATEWAY;
  try {
    const url = new URL(value);
    const expectedHost = `${new URL(SUPABASE_URL).hostname}`;
    if (url.protocol !== "https:" || url.hostname !== expectedHost) return DEFAULT_GATEWAY;
    if (!url.pathname.includes("/functions/v1/pi-model-gateway-guardian/v1")) return DEFAULT_GATEWAY;
    return url.toString().replace(/\/$/, "");
  } catch {
    return DEFAULT_GATEWAY;
  }
}

async function bodyObject(req: Request): Promise<JsonRecord> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) throw fail("payload_too_large", 413);
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) throw fail("payload_too_large", 413);
  try {
    const value = JSON.parse(raw || "{}");
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value as JsonRecord;
  } catch {
    throw fail("invalid_json", 400);
  }
}

async function userForAccessToken(token: string) {
  if (token.length < 20) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  if (data.user.app_metadata?.role !== "pi-gateway-client") return null;
  return data.user;
}

async function refreshSession(refreshToken: string): Promise<Session | null> {
  if (!publishableKey || refreshToken.length < 20 || refreshToken.length > 4096) return null;
  let response: Response;
  try {
    response = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        apikey: publishableKey,
        "user-agent": "openclaw-pi-infra-bootstrap/5",
      },
      body: JSON.stringify({ refresh_token: refreshToken }),
      signal: AbortSignal.timeout(12_000),
    });
  } catch {
    return null;
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok || typeof data?.access_token !== "string") return null;
  const user = await userForAccessToken(data.access_token);
  if (!user) return null;
  return {
    user,
    accessToken: data.access_token,
    refreshToken: typeof data.refresh_token === "string" ? data.refresh_token : refreshToken,
    expiresIn: Number.isFinite(Number(data.expires_in)) ? Number(data.expires_in) : null,
    refreshed: true,
  };
}

async function authenticate(req: Request, body: JsonRecord): Promise<Session | null> {
  const authorization = req.headers.get("authorization");
  const bearer = authorization?.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
  if (bearer) {
    const user = await userForAccessToken(bearer);
    if (user) return { user, accessToken: bearer, refreshToken: null, expiresIn: null, refreshed: false };
  }
  const refreshToken = bounded(body.refresh_token, 20, 4096);
  return refreshToken ? await refreshSession(refreshToken) : null;
}

function tailscaleClass(value: string): string {
  if (/^tskey-auth-/i.test(value)) return "node_auth_key";
  if (/^tskey-api-/i.test(value)) return "api_access_token";
  if (/^tskey-client-/i.test(value)) return "oauth_client_secret";
  if (/^tskey-/i.test(value)) return "tailscale_key_unknown_subtype";
  return "unknown_format";
}

async function openCodeModels(key: string) {
  try {
    const response = await fetch("https://opencode.ai/zen/v1/models", {
      headers: {
        authorization: `Bearer ${key}`,
        "user-agent": "openclaw-pi-infra-bootstrap/5",
      },
      signal: AbortSignal.timeout(12_000),
    });
    const data = await response.json().catch(() => ({}));
    const rows = Array.isArray(data?.data) ? data.data : Array.isArray(data) ? data : [];
    const ids = rows
      .map((model: unknown) => typeof model === "string" ? model : (model as JsonRecord)?.id)
      .filter((id: unknown): id is string => typeof id === "string");
    return {
      ok: response.ok,
      status: response.status,
      visibleCount: ids.length,
      discoverableFree: DISCOVERABLE_FREE_MODELS.filter((id) => ids.includes(id)),
    };
  } catch {
    return { ok: false, status: null as number | null, visibleCount: 0, discoverableFree: [] as string[] };
  }
}

async function controlsMap(keys: string[]): Promise<Record<string, boolean>> {
  const { data, error } = await admin
    .from("bridge_controls")
    .select("control_key,enabled")
    .in("control_key", keys);
  if (error) return {};
  return Object.fromEntries((data ?? []).map((row) => [row.control_key, Boolean(row.enabled)]));
}

async function loadCanonicalRoute(discoverable: string[]): Promise<CanonicalRoute> {
  const { data, error } = await admin
    .from("bridge_canonical_config")
    .select("config_value")
    .eq("config_key", "model.runtime_route")
    .eq("enabled", true)
    .maybeSingle();
  const config = !error && data?.config_value && typeof data.config_value === "object"
    ? data.config_value as JsonRecord
    : {};

  const configuredPrimary = providerId(config.primary);
  const primaryId = configuredPrimary && discoverable.includes(configuredPrimary)
    ? configuredPrimary
    : (discoverable.includes("nemotron-3-ultra-free") ? "nemotron-3-ultra-free" : (discoverable[0] ?? null));
  const configuredFallbacks = Array.isArray(config.fallbacks)
    ? config.fallbacks.map(providerId).filter((id): id is string => Boolean(id))
    : [];
  const fallbackIds = unique(configuredFallbacks)
    .filter((id) => id !== primaryId && discoverable.includes(id));
  const configuredUtility = providerId(config.utility_model);
  const utilityId = configuredUtility && discoverable.includes(configuredUtility) ? configuredUtility : primaryId;
  const quarantinedIds = config.quarantined_models && typeof config.quarantined_models === "object"
    ? unique(Object.keys(config.quarantined_models as JsonRecord)
      .map(providerId).filter((id): id is string => Boolean(id)))
    : [];
  const failurePolicy = config.failure_policy && typeof config.failure_policy === "object"
    ? config.failure_policy as JsonRecord
    : {
      on_429: "enqueue_and_backoff",
      on_503: "enqueue_and_backoff",
      on_timeout: "enqueue_and_backoff",
      surface_raw_provider_error_to_telegram: false,
    };
  return {
    baseUrl: safeGateway(config.base_url),
    primaryId,
    fallbackIds,
    utilityId,
    quarantinedIds,
    failurePolicy,
  };
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey.value || !publishableKey) return fail("server_not_configured", 503);
  if (req.method !== "POST") return fail("method_not_allowed", 405);

  let body: JsonRecord;
  try { body = await bodyObject(req); }
  catch (result) { return result instanceof Response ? result : fail("invalid_request", 400); }

  const session = await authenticate(req, body);
  if (!session) return fail("pi_session_refresh_required", 401);

  const action = bounded(body.action, 1, 40) ?? "status";
  const executionKey = bounded(body.execution_key ?? req.headers.get("x-execution-key"), 1, 128);
  const correlationId = bounded(body.correlation_id ?? req.headers.get("x-correlation-id"), 1, 128);
  if (!executionKey) return fail("execution_key_required", 400);
  if (!["status", "bootstrap"].includes(action)) return fail("unsupported_action", 400);

  const ledgerAction = `infra_${action}`;
  const { data: existing } = await admin.from("bridge_request_ledger")
    .select("allowed,reason").eq("user_id", session.user.id)
    .eq("action", ledgerAction).eq("execution_key", executionKey).maybeSingle();
  if (existing) return fail("duplicate_execution_key", 409);

  const { count, error: countError } = await admin.from("bridge_request_ledger")
    .select("request_id", { count: "exact", head: true })
    .eq("user_id", session.user.id).eq("action", "infra_bootstrap")
    .gte("created_at", new Date(Date.now() - 3_600_000).toISOString());
  if (countError) return fail("rate_limit_check_failed", 503);
  if (action === "bootstrap" && (count ?? 0) >= MAX_BOOTSTRAPS_PER_HOUR) {
    await admin.from("bridge_request_ledger").insert({
      user_id: session.user.id, action: ledgerAction, execution_key: executionKey,
      allowed: false, duplicate: false, reason: "rate_limit_exceeded",
    });
    return fail("rate_limit_exceeded", 429);
  }

  const opencode = Deno.env.get(OPENCODE_ALIAS)?.trim() ?? "";
  const tailscale = Deno.env.get(TAILSCALE_ALIAS)?.trim() ?? "";
  const catalog = opencode ? await openCodeModels(opencode)
    : { ok: false, status: null as number | null, visibleCount: 0, discoverableFree: [] as string[] };
  const route = await loadCanonicalRoute(catalog.discoverableFree);
  const tailscaleCredentialClass = tailscale ? tailscaleClass(tailscale) : "missing";
  const controls = await controlsMap(["opencode_zen_free_route", "tailscale_node_enrollment"]);
  const modelReady = Boolean(opencode && catalog.ok && route.primaryId && controls.opencode_zen_free_route === true);
  const tailscaleReady = Boolean(
    tailscale && tailscaleCredentialClass === "node_auth_key" && controls.tailscale_node_enrollment === true
  );
  const includeTailscaleAuthKey = action === "bootstrap" && body.include_tailscale_auth_key === true;
  const deliverTailscaleAuthKey = includeTailscaleAuthKey && tailscaleReady;

  await admin.from("bridge_request_ledger").insert({
    user_id: session.user.id, action: ledgerAction, execution_key: executionKey,
    allowed: action === "status" || modelReady, duplicate: false,
    reason: modelReady ? "admitted" : "model_infrastructure_not_ready",
  });

  await admin.from("bridge_events").insert({
    event_type: `pi_infra_${action}_v5`,
    node_name: "raspberry-pi5",
    correlation_id: correlationId,
    severity: modelReady ? "info" : "warning",
    outcome: modelReady ? "succeeded" : "blocked",
    detail: {
      actor_user_id: session.user.id,
      session_refreshed: session.refreshed,
      gateway_base_url: route.baseUrl,
      active_primary: route.primaryId,
      active_fallback_count: route.fallbackIds.length,
      quarantined_model_count: route.quarantinedIds.length,
      opencode_secret_server_side_only: true,
      opencode_catalog_status: catalog.status,
      tailscale_credential_class: tailscaleCredentialClass,
      tailscale_key_requested: includeTailscaleAuthKey,
      tailscale_key_delivered: deliverTailscaleAuthKey,
      runtime_server_key_type: adminKey.type,
      provider_secret_returned: false,
      values_logged: false,
      secret_values_included: false,
    },
    created_at: new Date().toISOString(),
  });

  const sessionPayload = session.refreshed ? {
    access_token: session.accessToken,
    refresh_token: session.refreshToken,
    expires_in: session.expiresIn,
    role: "pi-gateway-client",
  } : null;

  const provider = {
    id: "supabase-opencode",
    base_url: route.baseUrl,
    api: "openai-responses",
    credential_env: "PI_ACCESS_TOKEN",
    original_opencode_secret_server_side_only: true,
    primary: route.primaryId ? `supabase-opencode/${route.primaryId}` : null,
    fallbacks: route.fallbackIds.map((id) => `supabase-opencode/${id}`),
    utility_model: route.utilityId ? `supabase-opencode/${route.utilityId}` : null,
    models: unique([route.primaryId ?? "", ...route.fallbackIds]).filter(Boolean)
      .map((id) => ({ id, name: `OpenCode ${id}` })),
    quarantined_models: route.quarantinedIds.map((id) => `supabase-opencode/${id}`),
    failure_policy: route.failurePolicy,
    allowed_catalogs: ["supabase-opencode/*", "ollama/*"],
    paid_fallback_enabled: false,
    unavailable_model_to_remove: "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free",
  };

  if (action === "status") {
    return reply({
      ok: true,
      ready: modelReady,
      session: sessionPayload,
      provider,
      tailscale: {
        present: Boolean(tailscale), credential_class: tailscaleCredentialClass,
        node_enrollment_usable: tailscaleReady,
      },
      destination: "authenticated_pi_only",
      provider_secret_returned: false,
      tailscale_auth_key_returned: false,
      auth_session_returned: Boolean(sessionPayload),
      values_logged: false,
      secret_values_included: Boolean(sessionPayload),
    });
  }

  if (!modelReady || !route.primaryId || !route.utilityId) return fail("model_infrastructure_not_ready", 503);

  return reply({
    ok: true,
    session: sessionPayload,
    destination: "authenticated_pi_only",
    provider,
    tailscale: {
      auth_key: deliverTailscaleAuthKey ? tailscale : null,
      credential_class: tailscaleCredentialClass,
      hostname: "raspberry-pi5-openclaw",
      enable_ssh: true,
      funnel: false,
      one_time_delivery: deliverTailscaleAuthKey,
    },
    apply_policy: {
      update_agents_defaults_model: true,
      configure_supabase_model_proxy: true,
      update_agents_defaults_models_allowlist: true,
      set_utility_model: true,
      install_pi_token_refresh_timer: true,
      preserve_existing_telegram_poller: true,
      restart_gateway_after_validate: true,
      start_second_telegram_poller: false,
      export_original_provider_key_to_pi: false,
      enqueue_on_provider_overload: true,
      surface_raw_provider_error_to_telegram: false,
    },
    provider_secret_returned: false,
    tailscale_auth_key_returned: deliverTailscaleAuthKey,
    auth_session_returned: Boolean(sessionPayload),
    values_logged: false,
    cacheable: false,
    secret_values_included: Boolean(sessionPayload) || deliverTailscaleAuthKey,
  });
});