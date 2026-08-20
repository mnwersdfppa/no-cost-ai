import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SOURCE_URL = "https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/f491bf2e0a23ebad7302ce2e586e21021eb63f47/pi/install-openclaw-docker-compat.sh";
const EXPECTED_SHA256 = "f00e9b5bb8169bad33f6e89dd2b97faf004644dcd9b05f735e728438d65ed329";
const EXPECTED_BYTES = 6961;
const AGENT_SHA256 = "fab29d2a9ec3417b881b4e9735afac0e78f03d74d09f5310301d08ec7db76188";
const AGENT_COMMIT = "a71db8946d4658f90b28c3fd51e67dc98f6b54a2";
const IMAGE_DIGEST = "sha256:6c6df789c26cb0400171818fb0903d27ff799f9642d6e8c2eaf2b1c8e2e2894b";

function hex(bytes: Uint8Array): string {
  return [...bytes].map((value) => value.toString(16).padStart(2, "0")).join("");
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const input = Uint8Array.from(bytes).buffer;
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", input)));
}

function fail(error: string, status: number): Response {
  return Response.json({
    ok: false,
    error,
    provider_secret_returned: false,
    docker_registry_secret_returned: false,
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
        "user-agent": "supabase-openclaw-docker-compat-installer/1",
      },
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    return fail("pinned_source_unreachable", 503);
  }
  if (!upstream.ok) return fail(`pinned_source_http_${upstream.status}`, 502);

  const bytes = new Uint8Array(await upstream.arrayBuffer());
  const actual = await sha256(bytes);
  if (bytes.byteLength !== EXPECTED_BYTES) return fail("artifact_length_mismatch", 502);
  if (actual !== EXPECTED_SHA256) return fail("artifact_sha256_mismatch", 502);

  const text = new TextDecoder().decode(bytes);
  const required = [
    "#!/usr/bin/env bash\n",
    `AGENT_SHA256='${AGENT_SHA256}'`,
    AGENT_COMMIT,
    "DOCKER_GPG_FINGERPRINT='9DC858229FC7DD38854AE2D88D81803C0EBFCD88'",
    IMAGE_DIGEST,
    "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",
    "openclaw-docker-compat-preflight.timer",
    "NoNewPrivileges=true",
    "ProtectSystem=strict",
    "ProtectHome=read-only",
    "provider_secret_exported\": False",
    "docker_registry_secret_exported\": False",
    "second_telegram_poller_created\": False",
    "paid_api_fallback\": False",
  ];
  if (!text.startsWith(required[0])) return fail("artifact_shebang_invalid", 502);
  if (required.slice(1).some((marker) => !text.includes(marker))) {
    return fail("artifact_contract_missing", 502);
  }

  const forbidden = [
    /curl\s*\|\s*(?:sh|bash)/i,
    /docker\s+run[^\n]*--privileged/i,
    /-v\s+\/var\/run\/docker\.sock/i,
    /TELEGRAM_BOT_TOKEN\s*=/i,
    /OPENCODE_API_KEY\s*=/i,
    /OPENROUTER_API_KEY\s*=/i,
    /SUPABASE_SERVICE_ROLE_KEY\s*=/i,
    /dckr_(?:pat|oat)_[A-Za-z0-9_-]{8,}/i,
    /tskey-(?:auth|api|client)-[A-Za-z0-9_-]{8,}/i,
  ];
  if (forbidden.some((pattern) => pattern.test(text))) {
    return fail("artifact_forbidden_contract", 502);
  }

  return new Response(bytes, {
    status: 200,
    headers: {
      "content-type": "text/x-shellscript; charset=utf-8",
      "content-disposition": "attachment; filename=install-openclaw-docker-compat.sh",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "x-content-sha256": EXPECTED_SHA256,
      "x-agent-sha256": AGENT_SHA256,
      "x-image-digest": IMAGE_DIGEST,
      "x-provider-secret-included": "false",
      "x-docker-registry-secret-included": "false",
      "x-second-telegram-poller": "false",
      "x-paid-fallback": "false",
    },
  });
});
