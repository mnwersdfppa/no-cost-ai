import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 64 * 1024;
const MAX_EVIDENCE_BYTES = 16 * 1024;
const MAX_ERROR_CHARS = 1000;
const SECRET_LIKE = /(sk-proj-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]+|tskey-[A-Za-z0-9_-]+|Bearer\s+[A-Za-z0-9._~-]{16,}|BEGIN\s+(RSA|OPENSSH|EC)\s+PRIVATE\s+KEY)/i;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type AdminKeyType = "modern_secret_default" | "modern_secret_named" | "legacy_service_role_compatibility" | "missing";

function parseNamedKeySet(raw: string | undefined): Record<string,string> {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return Object.fromEntries(Object.entries(parsed).filter(([,v]) => typeof v === "string" && v.length > 0)) as Record<string,string>;
  } catch { return {}; }
}

function resolveAdminKey(): { value:string; selectedType:AdminKeyType; modernPresent:boolean; legacyPresent:boolean } {
  const modern = parseNamedKeySet(Deno.env.get("SUPABASE_SECRET_KEYS"));
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (modern.default) return { value:modern.default, selectedType:"modern_secret_default", modernPresent:true, legacyPresent:Boolean(legacy) };
  const first = Object.values(modern)[0];
  if (first) return { value:first, selectedType:"modern_secret_named", modernPresent:true, legacyPresent:Boolean(legacy) };
  if (legacy) return { value:legacy, selectedType:"legacy_service_role_compatibility", modernPresent:false, legacyPresent:true };
  return { value:"", selectedType:"missing", modernPresent:false, legacyPresent:false };
}

const adminKey = resolveAdminKey();
const admin = createClient(SUPABASE_URL, adminKey.value, {
  auth: { persistSession:false, autoRefreshToken:false },
});

function reply(body: unknown, status=200): Response {
  return new Response(JSON.stringify(body), { status, headers: {
    "content-type":"application/json; charset=utf-8",
    "cache-control":"no-store",
    "x-content-type-options":"nosniff",
    "referrer-policy":"no-referrer",
  }});
}

function redact(value: string): string {
  return value
    .replace(/sk-proj-[A-Za-z0-9_-]+/g,"[REDACTED]")
    .replace(/sk-[A-Za-z0-9_-]{20,}/g,"[REDACTED]")
    .replace(/ghp_[A-Za-z0-9]{20,}/g,"[REDACTED]")
    .replace(/xox[baprs]-[A-Za-z0-9-]+/g,"[REDACTED]")
    .replace(/tskey-[A-Za-z0-9_-]+/gi,"[REDACTED]")
    .replace(/Bearer\s+[A-Za-z0-9._~-]{16,}/gi,"Bearer [REDACTED]")
    .slice(0,MAX_ERROR_CHARS);
}

async function requirePi(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw reply({ok:false,error:"unauthorized",values_exposed:false},401);
  const { data,error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user) throw reply({ok:false,error:"unauthorized",values_exposed:false},401);
  if (data.user.app_metadata?.role !== "pi-gateway-client") throw reply({ok:false,error:"pi_identity_required",values_exposed:false},403);
  return data.user;
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey.value) return reply({ok:false,error:"server_not_configured",values_exposed:false},503);
  if (req.method !== "POST") return reply({ok:false,error:"method_not_allowed",values_exposed:false},405);

  let user;
  try { user = await requirePi(req); }
  catch (response) { return response instanceof Response ? response : reply({ok:false,error:"authentication_failed",values_exposed:false},401); }

  await admin.rpc("bridge_record_runtime_key_selection", {
    p_user_id:user.id,
    p_function_name:"pi-work-queue",
    p_selected_key_type:adminKey.selectedType,
    p_modern_key_present:adminKey.modernPresent,
    p_legacy_key_present:adminKey.legacyPresent,
    p_value_returned:false,
  });

  const declaredLength = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) return reply({ok:false,error:"body_too_large",values_exposed:false},413);
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) return reply({ok:false,error:"body_too_large",values_exposed:false},413);

  let body: Record<string,unknown>;
  try { body = JSON.parse(raw || "{}") as Record<string,unknown>; }
  catch { return reply({ok:false,error:"invalid_json",values_exposed:false},400); }

  const action = String(body.action ?? "status");
  if (action === "status") {
    const { data,error } = await admin.from("openclaw_work_queue")
      .select("status,priority,task_type,attempts,max_attempts,not_before,lease_until")
      .order("priority",{ascending:false});
    if (error) return reply({ok:false,error:"queue_read_failed",values_exposed:false},500);
    const counts: Record<string,number> = {};
    for (const row of data ?? []) counts[row.status] = (counts[row.status] ?? 0) + 1;
    return reply({ok:true,counts,tasks:data ?? [],runtime_server_key_type:adminKey.selectedType,values_exposed:false,server_secret_returned:false});
  }

  if (action === "pull" || action === "pull_recovery") {
    const requestedLease = Number(body.lease_minutes ?? 30);
    const leaseMinutes = Number.isFinite(requestedLease) ? Math.max(5,Math.min(Math.trunc(requestedLease),60)) : 30;
    const rpcName = action === "pull_recovery" ? "claim_openclaw_recovery_task" : "claim_openclaw_task";
    const { data,error } = await admin.rpc(rpcName,{p_user_id:user.id,p_lease_minutes:leaseMinutes});
    if (error) return reply({ok:false,error:action === "pull_recovery" ? "recovery_queue_claim_failed" : "queue_claim_failed",values_exposed:false},500);
    return reply({
      ok:true,
      task:data?.[0] ?? null,
      claim_scope:action === "pull_recovery" ? "deterministic_recovery_allowlist" : "general",
      runtime_server_key_type:adminKey.selectedType,
      values_exposed:false,
      server_secret_returned:false,
    });
  }

  const taskId = String(body.task_id ?? "");
  if (!UUID_RE.test(taskId)) return reply({ok:false,error:"valid_task_id_required",values_exposed:false},400);

  if (action === "complete") {
    const evidence = body.evidence && typeof body.evidence === "object" ? body.evidence : {};
    const serialized = JSON.stringify(evidence);
    if (new TextEncoder().encode(serialized).byteLength > MAX_EVIDENCE_BYTES) return reply({ok:false,error:"evidence_too_large",values_exposed:false},413);
    if (SECRET_LIKE.test(serialized)) return reply({ok:false,error:"secret_like_evidence_rejected",values_exposed:false},400);
    const now = new Date().toISOString();
    const { data,error } = await admin.from("openclaw_work_queue")
      .update({status:"completed",evidence,lease_until:null,completed_at:now,updated_at:now})
      .eq("id",taskId).eq("status","claimed").eq("claimed_by",user.id)
      .select("id,task_key,status").maybeSingle();
    if (error) return reply({ok:false,error:"queue_complete_failed",values_exposed:false},500);
    if (!data) return reply({ok:false,error:"task_not_claimed_by_pi",values_exposed:false},409);
    return reply({ok:true,task:data,values_exposed:false,server_secret_returned:false});
  }

  if (action === "fail") {
    const message = redact(String(body.error ?? "task_failed"));
    const { data:current,error:currentError } = await admin.from("openclaw_work_queue")
      .select("attempts,max_attempts").eq("id",taskId).eq("status","claimed").eq("claimed_by",user.id).maybeSingle();
    if (currentError) return reply({ok:false,error:"queue_read_failed",values_exposed:false},500);
    if (!current) return reply({ok:false,error:"task_not_claimed_by_pi",values_exposed:false},409);
    const terminal = current.attempts >= current.max_attempts;
    const now = new Date();
    const { data,error } = await admin.from("openclaw_work_queue")
      .update({
        status:terminal ? "failed" : "queued",
        last_error:message,
        lease_until:null,
        claimed_by:terminal ? user.id : null,
        not_before:terminal ? now.toISOString() : new Date(now.getTime()+5*60*1000).toISOString(),
        updated_at:now.toISOString(),
      })
      .eq("id",taskId).eq("status","claimed").eq("claimed_by",user.id)
      .select("id,task_key,status,attempts,max_attempts").maybeSingle();
    if (error) return reply({ok:false,error:"queue_fail_update_failed",values_exposed:false},500);
    if (!data) return reply({ok:false,error:"task_not_claimed_by_pi",values_exposed:false},409);
    return reply({ok:true,task:data,values_exposed:false,server_secret_returned:false});
  }

  return reply({ok:false,error:"unsupported_action",values_exposed:false},400);
});