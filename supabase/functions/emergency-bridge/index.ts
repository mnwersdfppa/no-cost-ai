import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 65_536;

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
  return reply({ ok: false, error: code, values_exposed: false }, status);
}

function boundedString(value: unknown, min: number, max: number): string | null {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result.length >= min && result.length <= max ? result : null;
}

function boundedRisk(value: unknown): number | null {
  const result = Number(value);
  return Number.isInteger(result) && result >= 0 && result <= 4 ? result : null;
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

async function recordEvent(
  eventType: string,
  nodeName: string | null,
  correlationId: string | null,
  severity: "debug" | "info" | "warning" | "error" | "critical",
  outcome: "observed" | "allowed" | "denied" | "succeeded" | "failed" | "blocked",
  detail: JsonRecord,
) {
  await admin.rpc("bridge_record_event", {
    p_event_type: eventType,
    p_node_name: nodeName,
    p_correlation_id: correlationId,
    p_severity: severity,
    p_outcome: outcome,
    p_detail: detail,
  });
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey.value) return fail("server_not_configured", 503);
  if (!["GET", "POST"].includes(req.method)) return fail("method_not_allowed", 405);

  let user;
  try {
    user = await requirePi(req);
  } catch (response) {
    return response instanceof Response ? response : fail("authentication_failed", 401);
  }

  let body: JsonRecord = {};
  if (req.method === "POST") {
    try {
      body = await parseBody(req);
    } catch (response) {
      return response instanceof Response ? response : fail("invalid_request", 400);
    }
  }

  const action = req.method === "GET"
    ? "status"
    : boundedString(body.action, 1, 80) ?? "status";
  const executionKey = boundedString(
    body.execution_key ?? req.headers.get("x-execution-key"),
    1,
    128,
  );
  const correlationId = boundedString(
    body.correlation_id ?? req.headers.get("x-correlation-id"),
    1,
    128,
  );

  const { data: admissionRows, error: admissionError } = await admin.rpc(
    "bridge_admit_request",
    {
      p_user_id: user.id,
      p_action: action,
      p_execution_key: executionKey,
    },
  );
  if (admissionError || !admissionRows?.[0]) return fail("admission_check_failed", 503);
  const admission = admissionRows[0];
  if (!admission.allowed) {
    await recordEvent("emergency_bridge_request", null, correlationId, "warning", "denied", {
      action,
      reason: admission.reason,
    });
    return reply(
      { ok: false, error: admission.reason, admission, values_exposed: false },
      admission.reason === "rate_limit_exceeded" ? 429 : 403,
    );
  }
  if (admission.duplicate && action === "heartbeat") {
    return reply({ ok: true, duplicate: true, admission, values_exposed: false });
  }

  await admin.rpc("bridge_record_runtime_key_selection", {
    p_user_id: user.id,
    p_function_name: "emergency-bridge",
    p_selected_key_type: adminKey.selectedType,
    p_modern_key_present: adminKey.modernPresent,
    p_legacy_key_present: adminKey.legacyPresent,
    p_value_returned: false,
  });
  await admin.rpc("bridge_reconcile_runtime_key_unification");

  if (action === "status") {
    const [snapshot, controls, credentials, aliases, routes, nodes, queue, runtimeKeys] = await Promise.all([
      admin.from("bridge_readiness_snapshot").select("*").maybeSingle(),
      admin.from("bridge_controls")
        .select("control_key,enabled,fail_closed,reason,expires_at,updated_at")
        .order("control_key"),
      admin.from("bridge_credentials")
        .select("integration,storage_scope,configured,validation_status,validation_detail,last_validated_at,rotation_due_at,read_only_default,runtime_presence")
        .order("integration"),
      admin.from("bridge_credential_alias_ssot")
        .select("alias_key,canonical_integration,source_scope,status,selected,configured,validation_status,read_only_default,last_validated_at")
        .eq("selected", true)
        .order("canonical_integration"),
      admin.from("bridge_route_registry")
        .select("route_key,integration,endpoint_alias,mode,capability,min_risk_tier,max_risk_tier,requires_control_key,priority,enabled,health_status,last_checked_at,notes")
        .order("priority"),
      admin.from("bridge_nodes")
        .select("node_name,node_type,status,last_seen_at,capabilities")
        .order("node_name"),
      admin.from("openclaw_work_queue").select("status"),
      admin.from("bridge_runtime_key_selection")
        .select("function_name,selected_key_type,modern_key_present,legacy_key_present,value_returned,last_reported_at")
        .order("function_name"),
    ]);
    if (
      snapshot.error || controls.error || credentials.error || aliases.error ||
      routes.error || nodes.error || queue.error || runtimeKeys.error
    ) {
      return fail("readiness_read_failed", 503);
    }
    const queueCounts: Record<string, number> = {};
    for (const row of queue.data ?? []) {
      queueCounts[row.status] = (queueCounts[row.status] ?? 0) + 1;
    }
    await recordEvent("emergency_bridge_status", null, correlationId, "info", "succeeded", {
      action,
      runtime_server_key_type: adminKey.selectedType,
    });
    return reply({
      ok: true,
      version: 7,
      admission,
      snapshot: snapshot.data,
      controls: controls.data,
      credentials: credentials.data,
      selected_aliases: aliases.data,
      routes: routes.data,
      nodes: nodes.data,
      queue_counts: queueCounts,
      runtime_key_receipts: runtimeKeys.data,
      policy: {
        paid_api_fallback: false,
        external_write_actions: false,
        phone_write_actions: false,
        public_shell_execution: false,
        telegram_single_poller_enforced: true,
      },
      runtime_server_key_type: adminKey.selectedType,
      secrets_returned: false,
      secret_names_returned: false,
      values_exposed: false,
    });
  }

  if (action === "heartbeat") {
    const nodeName = boundedString(body.node_name, 1, 100);
    const nodeType = boundedString(body.node_type, 1, 40);
    const status = boundedString(body.status, 1, 20);
    if (!nodeName || !nodeType || !status) return fail("invalid_heartbeat", 400);
    const capabilities = body.capabilities && typeof body.capabilities === "object" && !Array.isArray(body.capabilities)
      ? body.capabilities
      : {};
    const metadata = body.metadata && typeof body.metadata === "object" && !Array.isArray(body.metadata)
      ? body.metadata
      : {};
    const { data, error } = await admin.rpc("bridge_record_heartbeat", {
      p_user_id: user.id,
      p_node_name: nodeName,
      p_node_type: nodeType,
      p_status: status,
      p_capabilities: capabilities,
      p_metadata: metadata,
    });
    if (error) return fail("heartbeat_rejected", 400);
    await admin.rpc("refresh_bridge_route_health");
    await recordEvent("bridge_heartbeat", nodeName, correlationId, "info", "succeeded", {
      node_type: nodeType,
      status,
      runtime_server_key_type: adminKey.selectedType,
    });
    return reply({ ok: true, admission, node: data, values_exposed: false });
  }

  if (action === "policy_check") {
    const integration = boundedString(body.integration, 1, 80);
    const operation = boundedString(body.operation, 1, 80);
    if (!integration || !operation) {
      return fail("integration_and_operation_required", 400);
    }
    const { data, error } = await admin.rpc("bridge_policy_decision", {
      p_user_id: user.id,
      p_integration: integration,
      p_operation: operation,
    });
    if (error || !data?.[0]) return fail("policy_check_failed", 503);
    await recordEvent(
      "bridge_policy_check",
      null,
      correlationId,
      "info",
      data[0].allowed ? "allowed" : "denied",
      { integration, operation, reason: data[0].reason },
    );
    return reply({ ok: true, admission, decision: data[0], values_exposed: false });
  }

  if (action === "queue_status") {
    const { data, error } = await admin
      .from("openclaw_work_queue")
      .select("status,priority,task_type,attempts,max_attempts,not_before,lease_until")
      .order("priority", { ascending: false });
    if (error) return fail("queue_read_failed", 503);
    const counts: Record<string, number> = {};
    for (const row of data ?? []) {
      counts[row.status] = (counts[row.status] ?? 0) + 1;
    }
    return reply({ ok: true, admission, counts, tasks: data, values_exposed: false });
  }

  if (action === "resolve_route") {
    const capability = boundedString(body.capability, 1, 80);
    const riskTier = boundedRisk(body.risk_tier ?? 0);
    if (!capability || riskTier === null) {
      return fail("capability_and_valid_risk_tier_required", 400);
    }
    const { data, error } = await admin.rpc("bridge_resolve_route", {
      p_user_id: user.id,
      p_capability: capability,
      p_risk_tier: riskTier,
    });
    if (error || !data?.[0]) return fail("route_resolution_failed", 503);
    const route = data[0];
    await recordEvent(
      "bridge_route_resolution",
      null,
      correlationId,
      "info",
      route.decision === "route_selected" ? "allowed" : "blocked",
      {
        capability,
        risk_tier: riskTier,
        route_key: route.route_key,
        integration: route.integration,
        decision: route.decision,
      },
    );
    return reply({
      ok: true,
      admission,
      route,
      provider_called: false,
      credential_returned: false,
      values_exposed: false,
    });
  }

  return fail("unsupported_action", 400);
});
