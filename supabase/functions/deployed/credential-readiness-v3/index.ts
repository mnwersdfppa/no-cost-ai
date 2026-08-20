import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 16_384;

type JsonRecord = Record<string, unknown>;
type KeySelection = {
  value: string;
  selectedType:
    | "modern_secret_default"
    | "modern_secret_named"
    | "legacy_service_role_compatibility"
    | "missing";
  modernPresent: boolean;
  legacyPresent: boolean;
};

function parseNamedKeySet(raw: string | undefined): Record<string, string> {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return Object.fromEntries(
      Object.entries(parsed).filter(([, value]) =>
        typeof value === "string" && value.length > 0
      ),
    ) as Record<string, string>;
  } catch {
    return {};
  }
}

function resolveAdminKey(): KeySelection {
  const modern = parseNamedKeySet(Deno.env.get("SUPABASE_SECRET_KEYS"));
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (modern.default) {
    return {
      value: modern.default,
      selectedType: "modern_secret_default",
      modernPresent: true,
      legacyPresent: Boolean(legacy),
    };
  }
  const first = Object.values(modern)[0];
  if (typeof first === "string" && first.length > 0) {
    return {
      value: first,
      selectedType: "modern_secret_named",
      modernPresent: true,
      legacyPresent: Boolean(legacy),
    };
  }
  if (legacy) {
    return {
      value: legacy,
      selectedType: "legacy_service_role_compatibility",
      modernPresent: false,
      legacyPresent: true,
    };
  }
  return {
    value: "",
    selectedType: "missing",
    modernPresent: false,
    legacyPresent: false,
  };
}

const adminKey = resolveAdminKey();
const admin = createClient(SUPABASE_URL, adminKey.value, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const CREDENTIAL_GROUPS: Record<string, string[]> = Object.freeze({
  openai: ["OPENAI_API_KEY"],
  openrouter: ["OPENROUTER_API_KEY"],
  anthropic: ["ANTHROPIC_API_KEY"],
  perplexity: ["PERPLEXITY_API_KEY"],
  deepseek: ["DEEPSEEK_API_KEY"],
  maton: ["MATON_API_KEY", "MATON_API_TOKEN", "MATON_KEY"],
  make: ["MAKE_API_KEY", "MAKE_API_TOKEN", "MAKE_TOKEN", "MAKE_WEBHOOK_URL"],
  n8n: ["N8N_API_KEY", "N8N_OWNER_API_KEY", "N8N_BASE_URL", "N8N_WEBHOOK_URL"],
  telegram: ["TELEGRAM_BOT_TOKEN"],
  notion: ["NOTION_API_KEY", "NOTION_TOKEN"],
  github: ["GITHUB_TOKEN"],
  vercel: ["VERCEL_TOKEN", "VERCEL_API_TOKEN"],
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
  return reply(
    {
      ok: false,
      error: code,
      values_exposed: false,
      values_returned: false,
      prefixes_returned: false,
      hashes_returned: false,
      lengths_returned: false,
    },
    status,
  );
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
  if (data.user.app_metadata?.role !== "pi-gateway-client") {
    throw fail("pi_identity_required", 403);
  }
  return data.user;
}

async function parseBody(req: Request): Promise<JsonRecord> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    throw fail("payload_too_large", 413);
  }
  try {
    const value = await req.json();
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new Error("object required");
    }
    return value as JsonRecord;
  } catch {
    throw fail("invalid_json", 400);
  }
}

async function recordRuntimeKeySelection(userId: string): Promise<void> {
  const { error } = await admin.rpc("bridge_record_runtime_key_selection", {
    p_user_id: userId,
    p_function_name: "credential-readiness",
    p_selected_key_type: adminKey.selectedType,
    p_modern_key_present: adminKey.modernPresent,
    p_legacy_key_present: adminKey.legacyPresent,
    p_value_returned: false,
  });
  if (error) throw new Error("runtime_key_receipt_failed");
  const { error: reconcileError } = await admin.rpc(
    "bridge_reconcile_runtime_key_unification",
  );
  if (reconcileError) throw new Error("runtime_key_reconcile_failed");
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
    body = await parseBody(req);
  } catch (response) {
    return response instanceof Response ? response : fail("invalid_request", 400);
  }

  const executionKey = boundedString(
    body.execution_key ?? req.headers.get("x-execution-key"),
    1,
    128,
  );
  if (!executionKey) return fail("execution_key_required", 400);
  const correlationId = boundedString(
    body.correlation_id ?? req.headers.get("x-correlation-id"),
    1,
    128,
  );

  const { data: admissionRows, error: admissionError } = await admin.rpc(
    "bridge_admit_request",
    {
      p_user_id: user.id,
      p_action: "credential_readiness",
      p_execution_key: executionKey,
    },
  );
  if (admissionError || !admissionRows?.[0]) {
    return fail("admission_check_failed", 503);
  }
  const admission = admissionRows[0];
  if (!admission.allowed) {
    return reply(
      {
        ok: false,
        error: admission.reason,
        admission,
        values_exposed: false,
        values_returned: false,
        prefixes_returned: false,
        hashes_returned: false,
        lengths_returned: false,
      },
      admission.reason === "rate_limit_exceeded" ? 429 : 403,
    );
  }

  try {
    await recordRuntimeKeySelection(user.id);
  } catch {
    return fail("runtime_key_receipt_failed", 503);
  }

  if (admission.duplicate) {
    return reply({
      ok: true,
      duplicate: true,
      admission,
      runtime_server_key_type: adminKey.selectedType,
      values_exposed: false,
      values_returned: false,
      prefixes_returned: false,
      hashes_returned: false,
      lengths_returned: false,
    });
  }

  const now = new Date().toISOString();
  const results: Array<{
    integration: string;
    present_in_edge_runtime: boolean;
  }> = [];

  for (const [integration, aliases] of Object.entries(CREDENTIAL_GROUPS)) {
    const present = aliases.some((name) => Boolean(Deno.env.get(name)?.trim()));
    results.push({ integration, present_in_edge_runtime: present });

    const { data: current } = await admin
      .from("bridge_credentials")
      .select("integration,canonical_secret_name,detected_aliases,storage_scope,configured,validation_status,validation_detail,required_scopes,read_only_default,runtime_presence")
      .eq("integration", integration)
      .maybeSingle();

    const priorPresence = current?.runtime_presence &&
        typeof current.runtime_presence === "object"
      ? current.runtime_presence as JsonRecord
      : {};
    const protectedStatus = [
      "valid",
      "invalid",
      "blocked",
      "external_only",
    ].includes(current?.validation_status ?? "");

    await admin.from("bridge_credentials").upsert(
      {
        integration,
        canonical_secret_name: current?.canonical_secret_name ?? aliases[0],
        detected_aliases: current?.detected_aliases ?? [],
        storage_scope: present
          ? "supabase_edge_env"
          : current?.storage_scope ?? "unknown",
        configured: Boolean(current?.configured || present),
        validation_status: protectedStatus
          ? current!.validation_status
          : present
          ? "unverified"
          : current?.validation_status ?? "not_present",
        validation_detail: protectedStatus
          ? current?.validation_detail
          : present
          ? "Credential presence detected in Edge runtime; value was not read, hashed, measured, logged, or returned. Provider validation remains separate."
          : current?.validation_detail ??
            "Credential not present in this Edge runtime. It may exist in Pi-local secrets, OAuth device storage, n8n credentials, or a connected external connector.",
        required_scopes: current?.required_scopes ?? [],
        read_only_default: current?.read_only_default ?? true,
        runtime_presence: { ...priorPresence, supabase_edge_env: present },
        last_validated_at: now,
        updated_at: now,
      },
      { onConflict: "integration" },
    );
  }

  await admin.from("bridge_route_registry").update({
    health_status: "healthy",
    last_checked_at: now,
    updated_at: now,
  }).eq("route_key", "supabase.credential_readiness");

  await admin.rpc("bridge_record_event", {
    p_event_type: "credential_readiness_refresh",
    p_node_name: "raspberry-pi5",
    p_correlation_id: correlationId,
    p_severity: "info",
    p_outcome: "succeeded",
    p_detail: {
      actor_user_id: user.id,
      integrations_checked: results.length,
      runtime_server_key_type: adminKey.selectedType,
      values_exposed: false,
    },
  });

  return reply({
    ok: true,
    version: 7,
    admission,
    results,
    runtime_server_key_type: adminKey.selectedType,
    platform_managed_supabase_runtime: Boolean(
      SUPABASE_URL && adminKey.value,
    ),
    values_exposed: false,
    values_returned: false,
    prefixes_returned: false,
    hashes_returned: false,
    lengths_returned: false,
  });
});
