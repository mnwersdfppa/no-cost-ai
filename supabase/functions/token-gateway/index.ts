import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const OPENROUTER_API_KEY = Deno.env.get("OPENROUTER_API_KEY");
const allowedOperations = new Set(["chat", "summarize", "extract", "classify", "plan", "code"]);

Deno.serve(async (req: Request) => {
  const headers = { "content-type": "application/json" };
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ ok: false, error: "method_not_allowed" }), {
      status: 405,
      headers,
    });
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ ok: false, error: "invalid_json" }), {
      status: 400,
      headers,
    });
  }

  const operation = String(body?.operation ?? "chat");
  const input = body?.payload?.input;
  if (!allowedOperations.has(operation)) {
    return new Response(JSON.stringify({ ok: false, error: "operation_denied" }), {
      status: 403,
      headers,
    });
  }
  if (typeof input !== "string" || input.length < 1 || input.length > 20_000) {
    return new Response(JSON.stringify({ ok: false, error: "invalid_input" }), {
      status: 400,
      headers,
    });
  }

  // Zero-cost policy: paid OpenAI is never an automatic fallback.
  // Raspberry Pi should use local Ollama first. This compatibility gateway
  // only uses OpenRouter's free router when a validated OpenRouter key exists.
  if (!OPENROUTER_API_KEY) {
    return new Response(JSON.stringify({
      ok: false,
      error: "use_local_ollama",
      cost_policy: "zero_cost_first",
      local_endpoint: "http://127.0.0.1:11434/api/chat",
      suggested_model: "qwen2.5:3b",
      paid_fallback: false,
    }), { status: 409, headers });
  }

  const upstream = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${OPENROUTER_API_KEY}`,
    },
    body: JSON.stringify({
      model: "openrouter/free",
      messages: [{ role: "user", content: input }],
    }),
  });
  const data = await upstream.json().catch(() => ({}));
  if (!upstream.ok) {
    return new Response(JSON.stringify({
      ok: false,
      error: "free_provider_unavailable",
      provider_status: upstream.status,
      paid_fallback: false,
    }), { status: 502, headers });
  }

  return new Response(JSON.stringify({
    ok: true,
    provider: "openrouter",
    model: data?.model ?? "openrouter/free",
    result: data?.choices?.[0]?.message?.content ?? "",
    usage: data?.usage ?? null,
    billed_usd: 0,
    paid_fallback: false,
  }), { status: 200, headers });
});
