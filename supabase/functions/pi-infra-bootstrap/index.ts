import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 8192;
const MAX_BOOTSTRAPS_PER_HOUR = 3;
const OPENCODE_ALIAS = "Opencode-api-key";
const TAILSCALE_ALIAS = "Tailscale-fff-api-key";
const FREE_MODELS = [
  "nemotron-3-ultra-free",
  "deepseek-v4-flash-free",
  "mimo-v2.5-free",
  "big-pickle",
  "laguna-s-2.1-free",
];

type JsonRecord = Record<string, unknown>;

function parseNamed(raw: string | undefined): Record<string, string> {
  if (!raw) return {};
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter(([, candidate]) =>
        typeof candidate === "string" && candidate.length > 0
      ),
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

const adminKey = resolveAdmin();
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
    values_returned: false,
    values_logged: false,
    secret_values_included: false,
  }, status);
}

function bounded(value: unknown, min: number, max: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text.length >= min && text.length <= max ? text : null;
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

async function bodyObject(req: Request): Promise<JsonRecord> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    throw fail("payload_too_large", 413);
  }
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    throw fail("payload_too_large", 413);
  }
  try {
    const value = JSON.parse(raw || "{}");
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value as JsonRecord;
  } catch {
    throw fail("invalid_json", 400);
  }
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
        Authorization: `Bearer ${key}`,
        "user-agent": "openclaw-pi-infra-bootstrap/1",
      },
      signal: AbortSignal.timeout(12_000),
    });
    const payload = await response.json().catch(() => ({}));
    const rows = Array.isArray(payload?.data)
      ? payload.data
      : Array.isArray(payload)
      ? payload
      : [];
    const ids = rows
      .map((model: unknown) =>
        typeof model === "string"
          ? model
          : model && typeof model === "object" && "id" in model
          ? (model as { id?: unknown }).id
          : null
      )
      .filter((id: unknown): id is string => typeof id === "string");
    return {
      ok: response.ok,
      status: response.status,
      ids,
      free: FREE_MODELS.filter((id) => ids.includes(id)),
    };
  } catch {
    return {
      ok: false,
      status: null,
      ids: [] as string[],
      free: [] as string[],
    };
  }
}

async function controlsEnabled(keys: string[]): Promise<boolean> {
  const { data, error } = await admin
    .from("bridge_controls")
    .select("control_key,enabled")
    .in("control_key", keys);
  if (error) return false;
  const map = Object.fromEntries(
    (data ?? []).map((row) => [row.control_key, Boolean(row.enabled)]),
  );
  return keys.every((key) => map[key] === true);
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey.value) return fail("server_not_configured", 503);
  if (req.method !== "POST") return fail("method_not_allowed", 405);

  let user;
  try {
    user = await requirePi(req);
  } catch (response) {
    return response instanceof Response
      ? response
      : fail("authentication_failed", 401);
  }

  let body: JsonRecord;
  try {
    body = await bodyObject(req);
  } catch (response) {
    return response instanceof Response ? response : fail("invalid_request", 400);
  }

  const action = bounded(body.action, 1, 40) ?? "status";
  const executionKey = bounded(
    body.execution_key ?? req.headers.get("x-execution-key"),
    1,
    128,
  );
  const correlationId = bounded(
    body.correlation_id ?? req.headers.get("x-correlation-id"),
    1,
    128,
  );
  if (!executionKey) return fail("execution_key_required", 400);
  if (!["status", "bootstrap"].includes(action)) {
    return fail("unsupported_action", 400);
  }

  const ledgerAction = `infra_${action}`;
  const { data: existing } = await admin
    .from("bridge_request_ledger")
    .select("allowed,reason")
    .eq("user_id", user.id)
    .eq("action", ledgerAction)
    .eq("execution_key", executionKey)
    .maybeSingle();
  if (existing) return fail("duplicate_execution_key", 409);

  const { count, error: countError } = await admin
    .from("bridge_request_ledger")
    .select("request_id", { count: "exact", head: true })
    .eq("user_id", user.id)
    .eq("action", "infra_bootstrap")
    .gte("created_at", new Date(Date.now() - 3_600_000).toISOString());
  if (countError) return fail("rate_limit_check_failed", 503);
  if (action === "bootstrap" && (count ?? 0) >= MAX_BOOTSTRAPS_PER_HOUR) {
    await admin.from("bridge_request_ledger").insert({
      user_id: user.id,
      action: "infra_bootstrap",
      execution_key: executionKey,
      allowed: false,
      duplicate: false,
      reason: "rate_limit_exceeded",
    });
    return fail("rate_limit_exceeded", 429);
  }

  const opencode = Deno.env.get(OPENCODE_ALIAS)?.trim() ?? "";
  const tailscale = Deno.env.get(TAILSCALE_ALIAS)?.trim() ?? "";
  const catalog = opencode
    ? await openCodeModels(opencode)
    : {
      ok: false,
      status: null,
      ids: [] as string[],
      free: [] as string[],
    };
  const tailscaleCredentialClass = tailscale
    ? tailscaleClass(tailscale)
    : "missing";
  const controlsOk = await controlsEnabled([
    "opencode_zen_free_route",
    "tailscale_node_enrollment",
  ]);
  const ready = Boolean(
    opencode &&
      tailscale &&
      catalog.ok &&
      catalog.free.length > 0 &&
      tailscaleCredentialClass === "node_auth_key" &&
      controlsOk,
  );

  await admin.from("bridge_request_ledger").insert({
    user_id: user.id,
    action: ledgerAction,
    execution_key: executionKey,
    allowed: action === "status" || ready,
    duplicate: false,
    reason: ready ? "admitted" : "infrastructure_not_ready",
  });

  await admin.from("bridge_events").insert({
    event_type: `pi_infra_${action}`,
    node_name: "raspberry-pi5",
    correlation_id: correlationId,
    severity: ready ? "info" : "warning",
    outcome: ready ? "succeeded" : "blocked",
    detail: {
      actor_user_id: user.id,
      opencode_present: Boolean(opencode),
      opencode_status: catalog.status,
      free_model_count: catalog.free.length,
      tailscale_present: Boolean(tailscale),
      tailscale_credential_class: tailscaleCredentialClass,
      runtime_server_key_type: adminKey.type,
      values_returned: action === "bootstrap" && ready,
      values_logged: false,
      destination: "authenticated_pi_only",
      secret_values_included: false,
    },
    created_at: new Date().toISOString(),
  });

  if (action === "status") {
    return reply({
      ok: true,
      ready,
      opencode: {
        present: Boolean(opencode),
        valid: catalog.ok,
        status: catalog.status,
        free_models: catalog.free.map((id) => `opencode/${id}`),
      },
      tailscale: {
        present: Boolean(tailscale),
        credential_class: tailscaleCredentialClass,
        node_enrollment_usable: tailscaleCredentialClass === "node_auth_key",
      },
      destination: "authenticated_pi_only",
      values_returned: false,
      values_logged: false,
      secret_values_included: false,
    });
  }

  if (!ready) return fail("infrastructure_not_ready", 503);

  return reply({
    ok: true,
    destination: "authenticated_pi_only",
    provider: {
      OPENCODE_API_KEY: opencode,
      primary: "opencode/nemotron-3-ultra-free",
      fallbacks: [
        "opencode/deepseek-v4-flash-free",
        "opencode/mimo-v2.5-free",
        "opencode/big-pickle",
        "opencode/laguna-s-2.1-free",
      ].filter((ref) => catalog.free.includes(ref.slice("opencode/".length))),
      utility_model: catalog.free.includes("mimo-v2.5-free")
        ? "opencode/mimo-v2.5-free"
        : `opencode/${catalog.free[0]}`,
    },
    tailscale: {
      TAILSCALE_AUTHKEY: tailscale,
      credential_class: tailscaleCredentialClass,
      hostname: "raspberry-pi5-openclaw",
      enable_ssh: true,
      funnel: false,
    },
    values_returned: true,
    values_logged: false,
    cacheable: false,
    secret_values_included: true,
  });
});
