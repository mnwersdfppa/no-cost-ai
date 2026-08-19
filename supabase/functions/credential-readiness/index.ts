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

const secretKeys = parseDictionary("SUPABASE_SECRET_KEYS");
const adminKey = secretKeys.default ?? LEGACY_SERVICE_ROLE;
const admin = createClient(SUPABASE_URL, adminKey, {
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

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return reply({ ok: false, error: "method_not_allowed", values_exposed: false }, 405);
  }
  if (!SUPABASE_URL || !adminKey) {
    return reply({ ok: false, error: "server_not_configured", values_exposed: false }, 503);
  }

  let user;
  try {
    user = await requirePi(req);
  } catch (response) {
    if (response instanceof Response) return response;
    return reply({ ok: false, error: "authentication_failed", values_exposed: false }, 401);
  }

  const now = new Date().toISOString();
  const results: Array<{ integration: string; present_in_edge_runtime: boolean }> = [];

  for (const [integration, aliases] of Object.entries(CREDENTIAL_GROUPS)) {
    const present = aliases.some((name) => Boolean(Deno.env.get(name)?.trim()));
    results.push({ integration, present_in_edge_runtime: present });

    const { data: current } = await admin
      .from("bridge_credentials")
      .select("integration,canonical_secret_name,detected_aliases,storage_scope,configured,validation_status,validation_detail,required_scopes,read_only_default,runtime_presence")
      .eq("integration", integration)
      .maybeSingle();

    const existingPresence = current?.runtime_presence && typeof current.runtime_presence === "object"
      ? current.runtime_presence
      : {};
    const runtimePresence = { ...existingPresence, supabase_edge_env: present };
    const protectedStatus = ["valid", "invalid", "blocked", "external_only"].includes(
      current?.validation_status ?? "",
    );
    const validationStatus = protectedStatus
      ? current!.validation_status
      : present
        ? "unverified"
        : current?.validation_status ?? "not_present";

    await admin.from("bridge_credentials").upsert({
      integration,
      canonical_secret_name: current?.canonical_secret_name ?? aliases[0],
      detected_aliases: current?.detected_aliases ?? [],
      storage_scope: present ? "supabase_edge_env" : current?.storage_scope ?? "unknown",
      configured: Boolean(current?.configured || present),
      validation_status: validationStatus,
      validation_detail: protectedStatus
        ? current?.validation_detail
        : present
          ? "Credential presence detected in Edge runtime; value not read or returned. Provider validation remains separate."
          : current?.validation_detail ?? "Credential not present in this Edge runtime. It may exist in Pi local secrets, OAuth device storage, n8n credentials or a connected external connector.",
      required_scopes: current?.required_scopes ?? [],
      read_only_default: current?.read_only_default ?? true,
      runtime_presence: runtimePresence,
      last_validated_at: now,
      updated_at: now,
    }, { onConflict: "integration" });
  }

  await admin.rpc("bridge_record_event", {
    p_event_type: "credential_readiness_refresh",
    p_node_name: null,
    p_correlation_id: req.headers.get("x-correlation-id"),
    p_severity: "info",
    p_outcome: "succeeded",
    p_detail: {
      actor_user_id: user.id,
      integrations_checked: results.length,
      values_exposed: false,
    },
  });

  return reply({
    ok: true,
    results,
    platform_managed_supabase_runtime: Boolean(SUPABASE_URL && adminKey),
    selected_server_key_type: secretKeys.default ? "secret" : "legacy_service_role_compatibility",
    values_returned: false,
    prefixes_returned: false,
    hashes_returned: false,
    lengths_returned: false,
  });
});
