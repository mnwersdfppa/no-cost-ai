import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const EXPECTED = Object.freeze([
  "OPENAI_API_KEY",
  "MATON_API_KEY",
  "MAKE_API_TOKEN",
  "MAKE_WEBHOOK_SIGNING_SECRET",
]);

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET") return response({ ok: false, error: "method_not_allowed" }, 405);
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return response({ ok: false, error: "unauthorized" }, 401);
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) return response({ ok: false, error: "server_not_configured" }, 503);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { data, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user) return response({ ok: false, error: "unauthorized" }, 401);
  if (data.user.app_metadata?.role !== "pi-gateway-client") {
    return response({ ok: false, error: "pi_identity_required" }, 403);
  }

  const present = Object.fromEntries(EXPECTED.map((name) => [name, Boolean(Deno.env.get(name))]));
  return response({
    ok: true,
    present,
    values_returned: false,
    prefixes_returned: false,
    hashes_returned: false,
  });
});
