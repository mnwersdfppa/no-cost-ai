import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SOURCE_URL = "https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-openclaw-master-recovery-installer";
const EXPECTED_SHA256 = "d8e4792e759d898a2a3c7434e973b82fdeddd10e291ac1d4973276ece7216419";
const EXPECTED_BYTES = 2973;

async function sha256Bytes(bytes: Uint8Array): Promise<string> {
  const digestInput = bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
  const digest = await crypto.subtle.digest("SHA-256", digestInput);
  return [...new Uint8Array(digest)]
    .map((item) => item.toString(16).padStart(2, "0"))
    .join("");
}

function fail(error: string, status: number): Response {
  return Response.json({
    ok: false,
    error,
    provider_secret_returned: false,
    secret_values_included: false,
  }, {
    status,
    headers: {
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET") return fail("method_not_allowed", 405);

  let upstream: Response;
  try {
    upstream = await fetch(SOURCE_URL, {
      headers: { "user-agent": "supabase-current-master-recovery-verified/2" },
      signal: AbortSignal.timeout(30_000),
    });
  } catch {
    return fail("source_unreachable", 503);
  }
  if (!upstream.ok) return fail("source_fetch_failed", 502);

  const bytes = new Uint8Array(await upstream.arrayBuffer());
  if (bytes.byteLength !== EXPECTED_BYTES) return fail("artifact_length_mismatch", 502);
  if (await sha256Bytes(bytes) !== EXPECTED_SHA256) return fail("artifact_sha256_mismatch", 502);

  const text = new TextDecoder().decode(bytes);
  if (!text.startsWith("#!/usr/bin/env bash\n")) return fail("artifact_shebang_invalid", 502);
  for (const marker of [
    "pi-recovery-installer-current-format-verified",
    "pi-recovery-worker-current-format-verified",
    "pi-telegram-delivery-worker-installer",
    "refresh_token_minimum_chars\": 8",
    "server_retry_schedule\": \"2min\"",
    "sha256sum -c -",
    "provider_secret_exported\": False",
    "second_telegram_poller_created\": False",
  ]) {
    if (!text.includes(marker)) return fail("artifact_contract_missing", 502);
  }
  if (/curl\s*\|\s*(?:sh|bash)/i.test(text)) return fail("curl_pipe_shell_forbidden", 502);

  return new Response(bytes, {
    status: 200,
    headers: {
      "content-type": "text/x-shellscript; charset=utf-8",
      "content-disposition": "attachment; filename=install-openclaw-current-master-recovery.sh",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "x-content-sha256": EXPECTED_SHA256,
      "x-current-refresh-format": "true",
      "x-three-layer-recovery": "true",
      "x-server-retry-minutes": "2",
      "x-provider-secret-included": "false",
      "x-second-telegram-poller": "false",
    },
  });
});
