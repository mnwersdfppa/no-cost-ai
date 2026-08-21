import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 32 * 1024;
const MAX_EVIDENCE_BYTES = 16 * 1024;
const MAX_ERROR_CHARS = 500;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SECRET_LIKE = /(sk-proj-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]+|tskey-[A-Za-z0-9_-]+|Bearer\s+[A-Za-z0-9._~-]{16,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|BEGIN\s+(RSA|OPENSSH|EC)\s+PRIVATE\s+KEY)/i;

type JsonRecord = Record<string, unknown>;

function parseNamed(raw: string | undefined): Record<string, string> {
  if (!raw) return {};
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter(([, item]) => typeof item === "string" && item.length > 0),
    ) as Record<string, string>;
  } catch {
    return {};
  }
}

function resolveAdminKey(): string {
  const modern = parseNamed(Deno.env.get("SUPABASE_SECRET_KEYS"));
  if (modern.default) return modern.default;
  const first = Object.values(modern)[0];
  if (first) return first;
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

const ADMIN_KEY = resolveAdminKey();
const admin = createClient(SUPABASE_URL, ADMIN_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function reply(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
}

function safeError(value: unknown): string {
  return String(value ?? "delivery_failed")
    .replace(SECRET_LIKE, "[REDACTED]")
    .slice(0, MAX_ERROR_CHARS);
}

async function authenticate(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7).trim();
  if (token.length < 20) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  if (data.user.app_metadata?.role !== "pi-gateway-client") return null;
  return data.user;
}

async function parseBody(req: Request): Promise<JsonRecord | Response> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    return reply({ ok: false, error: "body_too_large", values_exposed: false }, 413);
  }
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    return reply({ ok: false, error: "body_too_large", values_exposed: false }, 413);
  }
  try {
    const value = JSON.parse(raw || "{}");
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value as JsonRecord;
  } catch {
    return reply({ ok: false, error: "invalid_json", values_exposed: false }, 400);
  }
}

async function ownedTask(taskId: string, userId: string) {
  return await admin
    .from("openclaw_work_queue")
    .select("id,task_key,task_type,status,attempts,max_attempts")
    .eq("id", taskId)
    .eq("task_type", "telegram_result_delivery")
    .eq("status", "claimed")
    .eq("claimed_by", userId)
    .maybeSingle();
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !ADMIN_KEY) {
    return reply({ ok: false, error: "server_not_configured", values_exposed: false }, 503);
  }
  if (req.method !== "POST") {
    return reply({ ok: false, error: "method_not_allowed", values_exposed: false }, 405);
  }

  const user = await authenticate(req);
  if (!user) return reply({ ok: false, error: "unauthorized", values_exposed: false }, 401);

  const parsed = await parseBody(req);
  if (parsed instanceof Response) return parsed;
  const body = parsed;
  const action = String(body.action ?? "status");

  if (action === "status") {
    const { data, error } = await admin
      .from("openclaw_work_queue")
      .select("status,priority,attempts,max_attempts,not_before,lease_until")
      .eq("task_type", "telegram_result_delivery")
      .order("priority", { ascending: false });
    if (error) return reply({ ok: false, error: "delivery_queue_read_failed", values_exposed: false }, 500);
    const counts: Record<string, number> = {};
    for (const row of data ?? []) counts[row.status] = (counts[row.status] ?? 0) + 1;
    return reply({
      ok: true,
      contract_version: 1,
      task_type: "telegram_result_delivery",
      delivery_mode: "openclaw_message_send",
      counts,
      values_exposed: false,
      server_secret_returned: false,
    });
  }

  if (action === "pull") {
    const requested = Number(body.lease_minutes ?? 10);
    const leaseMinutes = Number.isFinite(requested)
      ? Math.max(1, Math.min(Math.trunc(requested), 30))
      : 10;
    const { data, error } = await admin.rpc("bridge_claim_telegram_delivery_task", {
      p_user_id: user.id,
      p_lease_minutes: leaseMinutes,
    });
    if (error) return reply({ ok: false, error: "delivery_claim_failed", values_exposed: false }, 500);
    const task = data?.[0] ?? null;
    if (task && task.task_type !== "telegram_result_delivery") {
      return reply({ ok: false, error: "delivery_contract_violation", values_exposed: false }, 500);
    }
    return reply({
      ok: true,
      contract_version: 1,
      task,
      values_exposed: false,
      server_secret_returned: false,
    });
  }

  const taskId = String(body.task_id ?? "");
  if (!UUID_RE.test(taskId)) {
    return reply({ ok: false, error: "valid_task_id_required", values_exposed: false }, 400);
  }

  const current = await ownedTask(taskId, user.id);
  if (current.error) return reply({ ok: false, error: "delivery_queue_read_failed", values_exposed: false }, 500);
  if (!current.data) return reply({ ok: false, error: "delivery_task_not_claimed_by_pi", values_exposed: false }, 409);

  if (action === "complete") {
    const evidence = body.evidence && typeof body.evidence === "object" ? body.evidence : {};
    const serialized = JSON.stringify(evidence);
    if (new TextEncoder().encode(serialized).byteLength > MAX_EVIDENCE_BYTES) {
      return reply({ ok: false, error: "evidence_too_large", values_exposed: false }, 413);
    }
    if (SECRET_LIKE.test(serialized)) {
      return reply({ ok: false, error: "secret_like_evidence_rejected", values_exposed: false }, 400);
    }
    const now = new Date().toISOString();
    const { data, error } = await admin
      .from("openclaw_work_queue")
      .update({
        status: "completed",
        lease_until: null,
        completed_at: now,
        evidence: { ...evidence, secret_values_included: false },
        last_error: null,
        updated_at: now,
      })
      .eq("id", taskId)
      .eq("task_type", "telegram_result_delivery")
      .eq("status", "claimed")
      .eq("claimed_by", user.id)
      .select("id,task_key,task_type,status")
      .maybeSingle();
    if (error) return reply({ ok: false, error: "delivery_complete_failed", values_exposed: false }, 500);
    if (!data) return reply({ ok: false, error: "delivery_task_not_claimed_by_pi", values_exposed: false }, 409);
    return reply({ ok: true, task: data, values_exposed: false, server_secret_returned: false });
  }

  if (action === "fail") {
    const terminal = current.data.attempts >= current.data.max_attempts;
    const now = new Date();
    const { data, error } = await admin
      .from("openclaw_work_queue")
      .update({
        status: terminal ? "failed" : "queued",
        last_error: safeError(body.error),
        lease_until: null,
        claimed_by: terminal ? user.id : null,
        not_before: terminal ? now.toISOString() : new Date(now.getTime() + 5 * 60 * 1000).toISOString(),
        updated_at: now.toISOString(),
      })
      .eq("id", taskId)
      .eq("task_type", "telegram_result_delivery")
      .eq("status", "claimed")
      .eq("claimed_by", user.id)
      .select("id,task_key,task_type,status,attempts,max_attempts")
      .maybeSingle();
    if (error) return reply({ ok: false, error: "delivery_fail_update_failed", values_exposed: false }, 500);
    if (!data) return reply({ ok: false, error: "delivery_task_not_claimed_by_pi", values_exposed: false }, 409);
    return reply({ ok: true, task: data, values_exposed: false, server_secret_returned: false });
  }

  return reply({ ok: false, error: "unsupported_action", values_exposed: false }, 400);
});
