import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
type KeyMap = Record<string, string>;

function parseNamed(raw: string | undefined): KeyMap {
  if (!raw) return {};
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter(([, item]) =>
        typeof item === "string" && item.length > 0
      ),
    ) as KeyMap;
  } catch {
    return {};
  }
}

const secretSet = parseNamed(Deno.env.get("SUPABASE_SECRET_KEYS"));
const adminKey = secretSet.default ?? Object.values(secretSet)[0] ??
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const admin = createClient(SUPABASE_URL, adminKey, {
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

async function authenticate(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7).trim();
  if (token.length < 20) return null;
  const { data, error } = await admin.auth.getUser(token);
  return error || !data.user ? null : data.user;
}

Deno.serve(async (req: Request) => {
  if (!SUPABASE_URL || !adminKey) {
    return reply(
      { ok: false, error: "server_not_configured", secret_values_included: false },
      503,
    );
  }
  if (req.method !== "GET") {
    return reply(
      { ok: false, error: "method_not_allowed", secret_values_included: false },
      405,
    );
  }

  const user = await authenticate(req);
  if (!user) {
    return reply(
      { ok: false, error: "unauthorized", secret_values_included: false },
      401,
    );
  }

  const { data, error } = await admin.rpc("bridge_pattern_skill_readiness");
  if (error) {
    return reply(
      { ok: false, error: "readiness_query_failed", secret_values_included: false },
      503,
    );
  }

  return reply({
    ok: true,
    readiness: data,
    viewer_user_id: user.id,
    read_only: true,
    provider_secret_returned: false,
    secret_values_included: false,
  });
});
