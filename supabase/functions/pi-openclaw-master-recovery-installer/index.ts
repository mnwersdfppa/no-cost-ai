import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const BASE_RECOVERY_URL = `${SUPABASE_URL}/functions/v1/pi-recovery-installer-verified`;
const BASE_RECOVERY_SHA = "4c21d9eab6fff335950f8a4c8c7a064a20b9aa00aead487b811cee779e8ae947";
const DELIVERY_INSTALLER_URL = `${SUPABASE_URL}/functions/v1/pi-telegram-delivery-worker-installer`;
const DELIVERY_INSTALLER_SHA = "1db248ffbc0fea0bf22bcf17e2908134c9554f64539e1fe908dc0e2939268e97";
const CONFIG_KEY = "pi.master_recovery.installer_snapshot";

function parseNamed(raw: string | undefined): Record<string, string> {
  if (!raw) return {};
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter(([, item]) => typeof item === "string" && item.length > 0),
    ) as Record<string, string>;
  } catch {
    return {};
  }
}

function resolveAdminKey(): string {
  const modern = parseNamed(Deno.env.get("SUPABASE_SECRET_KEYS"));
  if (modern.default) return modern.default;
  const first = Object.values(modern)[0];
  if (first) return first;
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

const ADMIN_KEY = resolveAdminKey();
const admin = createClient(SUPABASE_URL, ADMIN_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

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

async function sha256Text(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digestInput = bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
  const digest = await crypto.subtle.digest("SHA-256", digestInput);
  return [...new Uint8Array(digest)]
    .map((item) => item.toString(16).padStart(2, "0"))
    .join("");
}

function buildScript(): string {
  return `#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="\${OPENCLAW_ROOT:-$HOME/.openclaw}"
RUNTIME_DIR="$ROOT/runtime"
RECEIPT="$RUNTIME_DIR/pi-openclaw-master-recovery-receipt.json"
TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

for command in bash curl python3 sha256sum; do
  command -v "$command" >/dev/null 2>&1 || { printf 'BLOCKED=missing_%s\\n' "$command" >&2; exit 40; }
done
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
  -o "$TMP/pi-recovery.sh" '${BASE_RECOVERY_URL}'
printf '%s  %s\\n' '${BASE_RECOVERY_SHA}' "$TMP/pi-recovery.sh" | sha256sum -c -
chmod 0700 "$TMP/pi-recovery.sh"
bash "$TMP/pi-recovery.sh"

curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
  -o "$TMP/pi-telegram-delivery-worker.sh" '${DELIVERY_INSTALLER_URL}'
printf '%s  %s\\n' '${DELIVERY_INSTALLER_SHA}' "$TMP/pi-telegram-delivery-worker.sh" | sha256sum -c -
chmod 0700 "$TMP/pi-telegram-delivery-worker.sh"
bash "$TMP/pi-telegram-delivery-worker.sh"

python3 - "$RECEIPT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    json.dumps(
        {
            "result": "installed",
            "model_and_auth_recovery": True,
            "telegram_delivery_worker": True,
            "base_recovery_sha256": "${BASE_RECOVERY_SHA}",
            "telegram_delivery_installer_sha256": "${DELIVERY_INSTALLER_SHA}",
            "guardian_gateway": "pi-model-gateway-guardian",
            "server_retry_schedule": "2min",
            "pi_delivery_schedule": "2min+jitter",
            "outbound_only_delivery": True,
            "second_telegram_poller_created": False,
            "paid_api_fallback": False,
            "provider_secret_exported": False,
            "secret_values_included": False,
        },
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
path.chmod(0o600)
PY

printf 'RESULT=installed component=openclaw-master-recovery receipt=%s\\n' "$RECEIPT"
`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET") return fail("method_not_allowed", 405);
  if (!SUPABASE_URL || !ADMIN_KEY) return fail("server_not_configured", 503);

  const script = buildScript();
  const sha256 = await sha256Text(script);
  const bytes = new TextEncoder().encode(script).byteLength;
  const { error } = await admin.from("bridge_canonical_config").upsert({
    config_key: CONFIG_KEY,
    config_value: {
      url: `${SUPABASE_URL}/functions/v1/pi-openclaw-master-recovery-installer`,
      sha256,
      bytes,
      base_recovery_url: BASE_RECOVERY_URL,
      base_recovery_sha256: BASE_RECOVERY_SHA,
      telegram_delivery_installer_url: DELIVERY_INSTALLER_URL,
      telegram_delivery_installer_sha256: DELIVERY_INSTALLER_SHA,
      guardian_gateway: "pi-model-gateway-guardian",
      server_retry_schedule: "*/2 * * * *",
      pi_delivery_schedule: "2min+jitter",
      outbound_only_delivery: true,
      second_telegram_poller_created: false,
      paid_api_fallback: false,
      provider_secret_included: false,
      generated_at: new Date().toISOString(),
    },
    sensitivity: "non_secret",
    enabled: true,
    source: "supabase-composed-verified-installers-v2",
    notes: "One-command Pi recovery installer composed from two exact SHA-pinned Supabase installers and the canonical two-minute server retry schedule.",
    updated_at: new Date().toISOString(),
  }, { onConflict: "config_key" });
  if (error) return fail("master_installer_snapshot_persist_failed", 503);

  return new Response(script, {
    status: 200,
    headers: {
      "content-type": "text/x-shellscript; charset=utf-8",
      "content-disposition": "attachment; filename=install-openclaw-master-recovery.sh",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "x-content-sha256": sha256,
      "x-secret-values-included": "false",
    },
  });
});
