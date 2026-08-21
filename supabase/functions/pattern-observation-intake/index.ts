import "jsr:@supabase/functions-js/edge-runtime.d.ts";

Deno.serve(() => Response.json({
  ok: false,
  error: "retired_use_openclaw_pattern_engine_observe",
  canonical_endpoint: "openclaw-pattern-engine",
  canonical_action: "observe",
  provider_secret_returned: false,
  secret_values_included: false,
}, {
  status: 410,
  headers: {
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
  },
}));
