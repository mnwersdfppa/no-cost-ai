import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 8192;
const MIN_REFRESH_TOKEN_CHARS = 8;

type KeyMap = Record<string, string>;

function parseNamedKeySet(raw: string | undefined): KeyMap {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return Object.fromEntries(
      Object.entries(parsed).filter(([, value]) => typeof value === "string" && value.length > 0),
    ) as KeyMap;
  } catch {
    return {};
  }
}

function resolvePublishable(): string {
  const modern = parseNamedKeySet(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"));
  if (modern.default) return modern.default;
  const first = Object.values(modern)[0];
  if (first) return first;
  return Deno.env.get("SUPABASE_ANON_KEY") ?? "";
}

function resolveAdmin(): string {
  const modern = parseNamedKeySet(Deno.env.get("SUPABASE_SECRET_KEYS"));
  if (modern.default) return modern.default;
  const first = Object.values(modern)[0];
  if (first) return first;
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

const publishable = resolvePublishable();
const adminKey = resolveAdmin();
const admin = createClient(SUPABASE_URL, adminKey, {
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

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply({ ok: false, error: "method_not_allowed" }, 405);
  if (!SUPABASE_URL || !publishable || !adminKey) return reply({ ok: false, error: "server_not_configured" }, 503);

  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return reply({ ok: false, error: "payload_too_large" }, 413);
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) return reply({ ok: false, error: "payload_too_large" }, 413);

  let body: Record<string, unknown>;
  try {
    const parsed = JSON.parse(raw || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
    body = parsed as Record<string, unknown>;
  } catch {
    return reply({ ok: false, error: "invalid_json" }, 400);
  }

  const refreshToken = typeof body.refresh_token === "string" ? body.refresh_token.trim() : "";
  if (refreshToken.length < MIN_REFRESH_TOKEN_CHARS || refreshToken.length > 4096) {
    return reply({ ok: false, error: "valid_refresh_token_required" }, 400);
  }

  let tokenResponse: Response;
  try {
    tokenResponse = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        apikey: publishable,
        "user-agent": "openclaw-pi-auth-refresh/5",
      },
      body: JSON.stringify({ refresh_token: refreshToken }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    return reply({ ok: false, error: "auth_refresh_unavailable" }, 503);
  }

  const tokenData = await tokenResponse.json().catch(() => ({}));
  if (!tokenResponse.ok || typeof tokenData?.access_token !== "string") {
    return reply({ ok: false, error: "refresh_rejected" }, 401);
  }

  const { data, error } = await admin.auth.getUser(tokenData.access_token);
  if (error || !data.user || data.user.app_metadata?.role !== "pi-gateway-client") {
    return reply({ ok: false, error: "pi_identity_required" }, 403);
  }

  return reply({
    ok: true,
    access_token: tokenData.access_token,
    refresh_token: typeof tokenData.refresh_token === "string" ? tokenData.refresh_token : refreshToken,
    expires_in: tokenData.expires_in ?? null,
    token_type: tokenData.token_type ?? "bearer",
    user_id: data.user.id,
    role: "pi-gateway-client",
    token_values_logged: false,
    server_secret_returned: false,
  });
});
