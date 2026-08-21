import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SOURCE_URL = "https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/dc1f6ecd54d6c2e9896b1a86af602c886e44e4c4/pi/install-openclaw-recovery-worker-current.sh";
const INSTALLER_SHA256 = "56094db3aeb87a757d433f29e8857fdde59d29a476415bd7928e6a218b086b92";
const WORKER_SHA256 = "bef134f66bb3da5187c3842db3e765471e02c0a058c70c7b79c57cf989112589";
const EXPECTED_BYTES = 3990;

function hex(bytes: Uint8Array): string {
  return [...bytes].map((value) => value.toString(16).padStart(2, "0")).join("");
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const input = Uint8Array.from(bytes).buffer;
  const digest = await crypto.subtle.digest("SHA-256", input);
  return hex(new Uint8Array(digest));
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
      headers: {
        "cache-control": "no-cache",
        "user-agent": "supabase-current-recovery-worker-installer/1",
      },
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    return fail("pinned_source_unreachable", 503);
  }
  if (!upstream.ok) return fail("pinned_source_fetch_failed", 502);

  const bytes = new Uint8Array(await upstream.arrayBuffer());
  if (bytes.byteLength !== EXPECTED_BYTES) return fail("artifact_length_mismatch", 502);
  if (await sha256(bytes) !== INSTALLER_SHA256) return fail("artifact_sha256_mismatch", 502);

  const text = new TextDecoder().decode(bytes);
  const required = [
    "#!/usr/bin/env bash",
    "openclaw-recovery-worker-current.py",
    "openclaw-pi-recovery-worker-current.service",
    "openclaw-pi-recovery-worker-current.timer",
    "MIN_REFRESH_TOKEN_CHARS = 8",
    "pi-recovery-installer-current-format-verified",
    WORKER_SHA256,
    "arbitrary_payload_execution\": False",
    "provider_secret_exported\": False",
    "second_telegram_poller_created\": False",
    "paid_api_fallback\": False",
  ];
  if (!required.every((marker) => text.includes(marker))) {
    return fail("artifact_contract_missing", 502);
  }

  const forbidden = [
    /sk-proj-[A-Za-z0-9_-]{16,}/,
    /ghp_[A-Za-z0-9]{20,}/,
    /tskey-(?:auth|api|client)-[A-Za-z0-9_-]{16,}/,
    /curl\s*\|\s*(?:sh|bash)/,
  ];
  if (forbidden.some((pattern) => pattern.test(text))) {
    return fail("artifact_forbidden_content", 502);
  }

  return new Response(bytes, {
    status: 200,
    headers: {
      "content-type": "text/x-shellscript; charset=utf-8",
      "content-disposition": "inline; filename=install-openclaw-recovery-worker-current.sh",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "x-content-sha256": INSTALLER_SHA256,
      "x-worker-sha256": WORKER_SHA256,
      "x-refresh-token-minimum-chars": "8",
      "x-provider-secret-included": "false",
      "x-second-telegram-poller": "false",
      "x-paid-fallback": "false",
    },
  });
});
