import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const MAX_BODY_BYTES = 8_192;
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
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

function boundedString(value: unknown, max = 128): string | null {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result.length > 0 && result.length <= max ? result : null;
}

async function requirePi(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw reply({ ok: false, error: "unauthorized", values_exposed: false }, 401);
  const { data, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user) throw reply({ ok: false, error: "unauthorized", values_exposed: false }, 401);
  if (data.user.app_metadata?.role !== "pi-gateway-client") {
    throw reply({ ok: false, error: "pi_identity_required", values_exposed: false }, 403);
  }
  return data.user;
}

async function parseBody(req: Request): Promise<Record<string, unknown>> {
  const length = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    throw reply({ ok: false, error: "payload_too_large", values_exposed: false }, 413);
  }
  try {
    const body = await req.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("object required");
    return body as Record<string, unknown>;
  } catch {
    throw reply({ ok: false, error: "invalid_json", values_exposed: false }, 400);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply({ ok: false, error: "method_not_allowed", values_exposed: false }, 405);
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) return reply({ ok: false, error: "server_not_configured", values_exposed: false }, 503);

  let user;
  let body: Record<string, unknown>;
  try {
    user = await requirePi(req);
    body = await parseBody(req);
  } catch (response) {
    if (response instanceof Response) return response;
    return reply({ ok: false, error: "request_rejected", values_exposed: false }, 400);
  }

  const correlationId = boundedString(body.correlation_id ?? req.headers.get("x-correlation-id"));
  const executionKey = boundedString(body.execution_key ?? req.headers.get("x-execution-key"));

  const { data: admissions, error: admissionError } = await admin.rpc("bridge_admit_request", {
    p_user_id: user.id,
    p_action: "credential_readiness",
    p_execution_key: executionKey,
  });
  if (admissionError || !admissions?.[0]) {
    return reply({ ok: false, error: "admission_check_failed", values_exposed: false }, 503);
  }
  const admission = admissions[0];
  if (!admission.allowed) {
    await admin.rpc("bridge_record_event", {
      p_event_type: "credential_readiness_request",
      p_node_name: null,
      p_correlation_id: correlationId,
      p_severity: "warning",
      p_outcome: "denied",
      p_detail: { reason: admission.reason },
    });
    return reply(
      { ok: false, error: admission.reason, admission, values_exposed: false },
      admission.reason === "rate_limit_exceeded" ? 429 : 403,
    );
  }

  const now = new Date().toISOString();
  const results: Array<{ integration: string; present_in_edge_runtime: boolean }> = [];

  for (const [integration, aliases] of Object.entries(CREDENTIAL_GROUPS)) {
    const present = aliases.some((name) => Boolean(Deno.env.get(name)?.trim()));
    results.push({ integration, present_in_edge_runtime: present });

    const { data: current } = await admin
      .from("bridge_credentials")
      .select("integration,storage_scope,configured,validation_status,validation_detail,required_scopes,read_only_default,runtime_presence")
      .eq("integration", integration)
      .maybeSingle();

    const existingPresence = current?.runtime_presence && typeof current.runtime_presence === "object"
      ? current.runtime_presence
      : {};
    const protectedStatus = ["valid", "invalid", "blocked", "external_only"].includes(current?.validation_status ?? "");

    await admin.from("bridge_credentials").upsert({
      integration,
      storage_scope: present ? "supabase_edge_env" : current?.storage_scope ?? "unknown",
      configured: Boolean(current?.configured || present),
      validation_status: protectedStatus
        ? current!.validation_status
        : present
          ? "unverified"
          : current?.validation_status ?? "not_present",
      validation_detail: protectedStatus
        ? current?.validation_detail
        : present
          ? "Presence detected in Edge runtime; provider validation remains separate."
          : current?.validation_detail ?? "Not present in this Edge runtime; another isolated runtime may own the credential.",
      required_scopes: current?.required_scopes ?? [],
      read_only_default: current?.read_only_default ?? true,
      runtime_presence: { ...existingPresence, supabase_edge_env: present },
      last_validated_at: now,
      updated_at: now,
    }, { onConflict: "integration" });
  }

  await admin.rpc("bridge_record_event", {
    p_event_type: "credential_readiness_refresh",
    p_node_name: null,
    p_correlation_id: correlationId,
    p_severity: "info",
    p_outcome: "succeeded",
    p_detail: {
      integrations_checked: results.length,
      duplicate_request: Boolean(admission.duplicate),
      values_exposed: false,
    },
  });

  return reply({
    ok: true,
    admission,
    results,
    platform_managed_supabase_runtime: true,
    values_returned: false,
    prefixes_returned: false,
    hashes_returned: false,
    lengths_returned: false,
    secret_names_returned: false,
    values_exposed: false,
  });
});
