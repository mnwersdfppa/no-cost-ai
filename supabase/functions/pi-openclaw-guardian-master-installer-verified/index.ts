import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SOURCE_URL = "https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/9237ba0c09b97a79a75464ad2e8e2e83972d5dc7/pi/install-openclaw-guardian-master.sh";
const SCRIPT_SHA256 = "bc938153e8b6bfe90dabb0471d34eaebef595aca6f5ec94db64d1b206cd8ce39";
const SCRIPT_BYTES = 3902;

async function sha256(bytes: Uint8Array): Promise<string> {
  const digestInput = Uint8Array.from(bytes).buffer;
  const digest = await crypto.subtle.digest("SHA-256", digestInput);
  return [...new Uint8Array(digest)]
    .map((value) => value.toString(16).padStart(2, "0"))
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
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET") return fail("method_not_allowed", 405);

  let upstream: Response;
  try {
    upstream = await fetch(SOURCE_URL, {
      headers: {
        "cache-control": "no-cache",
        "user-agent": "supabase-openclaw-guardian-master-installer/1",
      },
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    return fail("pinned_source_unreachable", 503);
  }

  if (!upstream.ok) return fail("pinned_source_fetch_failed", 502);
  const bytes = new Uint8Array(await upstream.arrayBuffer());
  if (bytes.byteLength !== SCRIPT_BYTES) return fail("artifact_length_mismatch", 502);
  if (await sha256(bytes) !== SCRIPT_SHA256) return fail("artifact_sha256_mismatch", 502);

  const text = new TextDecoder().decode(bytes);
  if (!text.startsWith("#!/usr/bin/env bash\n")) return fail("artifact_shebang_invalid", 502);
  for (const marker of [
    "PI_REFRESH_TOKEN",
    "pi-recovery-installer-verified",
    "pi-recovery-worker-installer-verified",
    "sha256sum --check --status",
    "provider_secret_exported\": false",
    "second_telegram_poller\": false",
  ]) {
    if (!text.includes(marker)) return fail("artifact_contract_missing", 502);
  }

  return new Response(bytes, {
    status: 200,
    headers: {
      "content-type": "text/x-shellscript; charset=utf-8",
      "content-disposition": "attachment; filename=install-openclaw-guardian-master.sh",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "x-openclaw-artifact-sha256": SCRIPT_SHA256,
      "x-openclaw-provider-secret-included": "false",
      "x-openclaw-second-telegram-poller": "false",
      "x-openclaw-paid-fallback": "false",
    },
  });
});
