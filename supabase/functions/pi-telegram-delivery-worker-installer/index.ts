import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const REPOSITORY = "mnwersdfppa/no-cost-ai";
const COMMIT = "292aae516c8c174c7174b88be1e8ff42d1223a99";
const CONFIG_KEY = "pi.telegram_delivery_worker.installer_snapshot";
const MAX_SOURCE_BYTES = 180_000;
const SOURCES = [
  {
    path: "pi/openclaw-telegram-delivery-worker.py",
    name: "openclaw-telegram-delivery-worker.py",
    mode: "0700",
    markers: [
      "pi-result-delivery-queue",
      "telegram_result_delivery",
      "openclaw",
      "message",
      "send",
      "channels.telegram.allowFrom",
      "outbound_only",
      "second_poller_created",
    ],
  },
  {
    path: "pi/install-openclaw-telegram-delivery-worker.sh",
    name: "install-openclaw-telegram-delivery-worker.sh",
    mode: "0700",
    markers: [
      "openclaw-telegram-delivery-worker.service",
      "openclaw-telegram-delivery-worker.timer",
      "OnUnitActiveSec=2min",
      "Type=oneshot",
      "pi-work-queue.env",
    ],
  },
] as const;

type SourceFile = { name: string; content: string; sha256: string; mode: string };

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
let cached: { script: string; sha256: string; bytes: number; files: SourceFile[] } | null = null;

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

function base64(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 8192) {
    binary += String.fromCharCode(...bytes.subarray(offset, Math.min(offset + 8192, bytes.length)));
  }
  return btoa(binary);
}

function validateSource(path: string, content: string, markers: readonly string[]): void {
  if (!content.startsWith("#!")) throw new Error(`source_shebang_missing:${path}`);
  if (new TextEncoder().encode(content).byteLength > MAX_SOURCE_BYTES) {
    throw new Error(`source_too_large:${path}`);
  }
  for (const marker of markers) {
    if (!content.includes(marker)) throw new Error(`source_marker_missing:${path}:${marker}`);
  }
  const forbidden = [
    "shell" + "=True",
    "eval" + "(task",
    "exec" + "(task",
    "get" + "Updates",
    "TELEGRAM_" + "BOT_TOKEN",
    "p" + "kill",
    "kill" + " -9",
    "curl | sh",
    "rm -rf /",
  ];
  for (const marker of forbidden) {
    if (content.includes(marker)) throw new Error(`source_forbidden:${path}:${marker}`);
  }
  const credentialLike = /(sk-proj-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|tskey-(auth|api|client)-[A-Za-z0-9_-]{16,})/;
  if (credentialLike.test(content)) throw new Error(`credential_literal:${path}`);
}

async function loadSources(): Promise<SourceFile[]> {
  const files: SourceFile[] = [];
  for (const source of SOURCES) {
    const url = `https://raw.githubusercontent.com/${REPOSITORY}/${COMMIT}/${source.path}`;
    const response = await fetch(url, {
      headers: { "user-agent": "supabase-openclaw-telegram-delivery-installer/2" },
      signal: AbortSignal.timeout(20_000),
    });
    if (!response.ok) throw new Error(`github_raw_${response.status}:${source.path}`);
    const content = await response.text();
    validateSource(source.path, content, source.markers);
    files.push({
      name: source.name,
      content,
      sha256: await sha256Text(content),
      mode: source.mode,
    });
  }
  return files;
}

function heredocName(name: string): string {
  return name.replaceAll(".", "_").replaceAll("-", "_").toUpperCase();
}

function buildInstaller(files: SourceFile[]): string {
  const blocks = files.map((file) => {
    const marker = heredocName(file.name);
    return `cat >"$TMP/${file.name}.b64" <<'B64_${marker}'\n${base64(file.content)}\nB64_${marker}\nbase64 -d "$TMP/${file.name}.b64" >"$TMP/${file.name}"\nprintf '%s  %s\\n' '${file.sha256}' "$TMP/${file.name}" | sha256sum -c -\nchmod ${file.mode} "$TMP/${file.name}"\n`;
  }).join("\n");
  const sourceHashes = JSON.stringify(Object.fromEntries(files.map((file) => [file.name, file.sha256])));

  return `#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="\${OPENCLAW_ROOT:-$HOME/.openclaw}"
RUNTIME_DIR="$ROOT/runtime"
RECEIPT="$RUNTIME_DIR/pi-telegram-delivery-worker-bootstrap-receipt.json"
TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

for command in bash base64 python3 sha256sum systemctl openclaw; do
  command -v "$command" >/dev/null 2>&1 || { printf 'BLOCKED=missing_%s\\n' "$command" >&2; exit 40; }
done
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

${blocks}
bash "$TMP/install-openclaw-telegram-delivery-worker.sh"

python3 - "$RECEIPT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    json.dumps(
        {
            "result": "installed",
            "repository": "${REPOSITORY}",
            "commit": "${COMMIT}",
            "source_sha256": ${sourceHashes},
            "queue_endpoint": "pi-result-delivery-queue",
            "task_type": "telegram_result_delivery",
            "delivery_command": "openclaw message send",
            "outbound_only": True,
            "second_telegram_poller_created": False,
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

printf 'RESULT=installed component=openclaw-telegram-delivery-worker receipt=%s\\n' "$RECEIPT"
`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET") return fail("method_not_allowed", 405);
  if (!SUPABASE_URL || !ADMIN_KEY) return fail("server_not_configured", 503);
  try {
    if (!cached) {
      const files = await loadSources();
      const script = buildInstaller(files);
      cached = {
        script,
        sha256: await sha256Text(script),
        bytes: new TextEncoder().encode(script).byteLength,
        files,
      };
      const { error } = await admin.from("bridge_canonical_config").upsert({
        config_key: CONFIG_KEY,
        config_value: {
          url: `${SUPABASE_URL}/functions/v1/pi-telegram-delivery-worker-installer`,
          sha256: cached.sha256,
          bytes: cached.bytes,
          repository: REPOSITORY,
          commit: COMMIT,
          source_sha256: Object.fromEntries(files.map((file) => [file.name, file.sha256])),
          queue_endpoint: "pi-result-delivery-queue",
          task_type: "telegram_result_delivery",
          delivery_command: "openclaw message send",
          outbound_only: true,
          second_telegram_poller_created: false,
          provider_secret_included: false,
          generated_at: new Date().toISOString(),
        },
        sensitivity: "non_secret",
        enabled: true,
        source: "supabase-generated-github-pinned-installer",
        notes: "Pinned, self-verifying installer for the outbound-only Pi Telegram result delivery worker.",
        updated_at: new Date().toISOString(),
      }, { onConflict: "config_key" });
      if (error) throw new Error("installer_snapshot_persist_failed");
    }

    return new Response(cached.script, {
      status: 200,
      headers: {
        "content-type": "text/x-shellscript; charset=utf-8",
        "content-disposition": "attachment; filename=install-openclaw-telegram-delivery-worker.sh",
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
        "x-content-sha256": cached.sha256,
        "x-github-commit": COMMIT,
        "x-secret-values-included": "false",
      },
    });
  } catch (error) {
    return fail(error instanceof Error ? error.message : "installer_generation_failed", 502);
  }
});
