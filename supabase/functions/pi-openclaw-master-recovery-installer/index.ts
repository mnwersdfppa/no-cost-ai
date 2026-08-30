import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MODEL_AUTH_URL = `${SUPABASE_URL}/functions/v1/pi-recovery-installer-current-format-verified`;
const MODEL_AUTH_SHA = "0754e14b097578edfc2659390456162f88053c70d9610578d686438faa389f54";
const RECOVERY_WORKER_URL = `${SUPABASE_URL}/functions/v1/pi-recovery-worker-current-format-verified`;
const RECOVERY_WORKER_SHA = "56094db3aeb87a757d433f29e8857fdde59d29a476415bd7928e6a218b086b92";
const DELIVERY_URL = `${SUPABASE_URL}/functions/v1/pi-telegram-delivery-worker-installer`;
const DELIVERY_SHA = "1db248ffbc0fea0bf22bcf17e2908134c9554f64539e1fe908dc0e2939268e97";
const CONFIG_KEY = "pi.master_recovery.installer_snapshot";

type JsonRecord = Record<string, unknown>;

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
RUNTIME_DIR="\${OPENCLAW_RUNTIME_DIR:-$ROOT/runtime}"
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
  -o "$TMP/model-auth.sh" '${MODEL_AUTH_URL}'
printf '%s  %s\\n' '${MODEL_AUTH_SHA}' "$TMP/model-auth.sh" | sha256sum -c -
chmod 0700 "$TMP/model-auth.sh"
bash "$TMP/model-auth.sh"

curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
  -o "$TMP/recovery-worker.sh" '${RECOVERY_WORKER_URL}'
printf '%s  %s\\n' '${RECOVERY_WORKER_SHA}' "$TMP/recovery-worker.sh" | sha256sum -c -
chmod 0700 "$TMP/recovery-worker.sh"
bash "$TMP/recovery-worker.sh"

curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
  -o "$TMP/telegram-delivery.sh" '${DELIVERY_URL}'
printf '%s  %s\\n' '${DELIVERY_SHA}' "$TMP/telegram-delivery.sh" | sha256sum -c -
chmod 0700 "$TMP/telegram-delivery.sh"
bash "$TMP/telegram-delivery.sh"

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
            "recovery_queue_worker": True,
            "telegram_delivery_worker": True,
            "model_auth_sha256": "${MODEL_AUTH_SHA}",
            "recovery_worker_sha256": "${RECOVERY_WORKER_SHA}",
            "telegram_delivery_sha256": "${DELIVERY_SHA}",
            "refresh_token_minimum_chars": 8,
            "guardian_gateway": "pi-model-gateway-guardian",
            "server_retry_schedule": "2min",
            "pi_recovery_schedule": "2min+jitter",
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
      model_auth_url: MODEL_AUTH_URL,
      model_auth_sha256: MODEL_AUTH_SHA,
      recovery_worker_url: RECOVERY_WORKER_URL,
      recovery_worker_sha256: RECOVERY_WORKER_SHA,
      telegram_delivery_url: DELIVERY_URL,
      telegram_delivery_sha256: DELIVERY_SHA,
      refresh_token_minimum_chars: 8,
      guardian_gateway: "pi-model-gateway-guardian",
      server_retry_schedule: "*/2 * * * *",
      pi_recovery_schedule: "2min+jitter",
      pi_delivery_schedule: "2min+jitter",
      outbound_only_delivery: true,
      second_telegram_poller_created: false,
      paid_api_fallback: false,
      provider_secret_included: false,
      generated_at: new Date().toISOString(),
    },
    sensitivity: "non_secret",
    enabled: true,
    source: "supabase-current-format-verified-stack-v2",
    notes: "Current-format three-layer Pi recovery installer with exact SHA-pinned model/auth, recovery queue and Telegram delivery installers plus the canonical two-minute server retry schedule.",
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
