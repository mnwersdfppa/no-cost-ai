import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const MAX_BODY_BYTES = 16_384;
const MIN_REFRESH_TOKEN_CHARS = 8;

type JsonRecord = Record<string, unknown>;
type Session = {
  user: { id: string; app_metadata?: Record<string, unknown> };
  accessToken: string;
  refreshToken: string | null;
  expiresIn: number | null;
  refreshed: boolean;
};

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

function resolveAdmin(): string {
  const modern = parseNamed(Deno.env.get("SUPABASE_SECRET_KEYS"));
  return modern.default ?? Object.values(modern)[0] ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

function resolvePublishable(): string {
  const modern = parseNamed(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"));
  return modern.default ?? Object.values(modern)[0] ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
}

const ADMIN_KEY = resolveAdmin();
const PUBLISHABLE_KEY = resolvePublishable();
const admin = createClient(SUPABASE_URL, ADMIN_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function reply(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
}

function fail(error: string, status: number): Response {
  return reply({
    ok: false,
    error,
    provider_secret_returned: false,
    docker_registry_secret_returned: false,
    secret_values_included: false,
  }, status);
}

function bounded(value: unknown, min: number, max: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text.length >= min && text.length <= max ? text : null;
}

function integer(value: unknown, min: number, max: number): number | null {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < min || parsed > max) return null;
  return parsed;
}

function normalizeArch(value: string): string {
  const name = value.trim().toLowerCase();
  if (["x86_64", "amd64", "x64"].includes(name)) return "amd64";
  if (["aarch64", "arm64", "arm64v8", "armv8l"].includes(name)) return "arm64";
  if (["armv7l", "armhf", "arm/v7"].includes(name)) return "arm/v7";
  return name;
}

async function bodyObject(req: Request): Promise<JsonRecord> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) throw fail("payload_too_large", 413);
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) throw fail("payload_too_large", 413);
  try {
    const parsed = JSON.parse(raw || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
    return parsed as JsonRecord;
  } catch {
    throw fail("invalid_json", 400);
  }
}

async function userForAccess(token: string) {
  if (token.length < 20) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user || data.user.app_metadata?.role !== "pi-gateway-client") return null;
  return data.user;
}

async function refreshSession(refreshToken: string): Promise<Session | null> {
  if (!PUBLISHABLE_KEY || refreshToken.length < MIN_REFRESH_TOKEN_CHARS || refreshToken.length > 4096) return null;
  try {
    const response = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
      method: "POST",
      headers: {
        apikey: PUBLISHABLE_KEY,
        "content-type": "application/json",
        "user-agent": "openclaw-pi-container-bootstrap/3",
      },
      body: JSON.stringify({ refresh_token: refreshToken }),
      signal: AbortSignal.timeout(12_000),
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || typeof data?.access_token !== "string") return null;
    const user = await userForAccess(data.access_token);
    if (!user) return null;
    return {
      user,
      accessToken: data.access_token,
      refreshToken: typeof data.refresh_token === "string" ? data.refresh_token : refreshToken,
      expiresIn: Number.isFinite(Number(data.expires_in)) ? Number(data.expires_in) : null,
      refreshed: true,
    };
  } catch {
    return null;
  }
}

async function authenticate(req: Request, body: JsonRecord): Promise<Session | null> {
  const authorization = req.headers.get("authorization");
  const bearer = authorization?.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
  if (bearer) {
    const user = await userForAccess(bearer);
    if (user) return { user, accessToken: bearer, refreshToken: null, expiresIn: null, refreshed: false };
  }
  const refresh = bounded(body.refresh_token, MIN_REFRESH_TOKEN_CHARS, 4096);
  return refresh ? await refreshSession(refresh) : null;
}

async function loadRuntimePolicy(): Promise<JsonRecord> {
  const { data } = await admin.from("bridge_canonical_config")
    .select("config_value")
    .eq("config_key", "container.runtime_policy")
    .eq("enabled", true)
    .maybeSingle();
  return data?.config_value && typeof data.config_value === "object"
    ? data.config_value as JsonRecord
    : {};
}

function typedExecutionPlan(strategy: JsonRecord, policy: JsonRecord, hostArch: string): JsonRecord {
  const selected = String(strategy.selected_strategy ?? "blocked_no_safe_route");
  const imageByDigest = typeof policy.image_by_digest === "string"
    ? policy.image_by_digest
    : typeof strategy.prebuilt_image === "string" && typeof strategy.prebuilt_digest === "string"
      ? `${String(strategy.prebuilt_image).replace(/:[^/:]+$/, "")}@${strategy.prebuilt_digest}`
      : null;
  const nativeUrl = typeof strategy.native_fallback_url === "string"
    ? strategy.native_fallback_url
    : typeof policy.native_fallback_url === "string" ? policy.native_fallback_url : null;
  const nativeSha = typeof strategy.native_fallback_sha256 === "string"
    ? strategy.native_fallback_sha256
    : typeof policy.native_fallback_sha256 === "string" ? policy.native_fallback_sha256 : null;

  if (selected === "container_prebuilt_then_native_recovery" && imageByDigest && nativeUrl && nativeSha) {
    return {
      route: selected,
      steps: [
        { type: "docker_pull", executable: "docker", args: ["pull", `--platform=linux/${hostArch}`, imageByDigest], shell: false },
        {
          type: "docker_preflight",
          executable: "docker",
          args: [
            "run", "--rm", "--pull=never", "--read-only", "--network=none",
            "--cap-drop=ALL", "--security-opt=no-new-privileges", "--pids-limit=64",
            "--memory=128m", "--cpus=0.5", `--platform=linux/${hostArch}`,
            imageByDigest, "status",
          ],
          shell: false,
          expected_json: { ok: true, secret_values_included: false },
        },
        { type: "download_verified_installer", url: nativeUrl, sha256: nativeSha, maximum_bytes: 1_048_576 },
        { type: "execute_verified_installer", executable: "bash", args: ["<verified_download_path>"], shell: false },
      ],
    };
  }
  if (selected === "container_local_build_then_native_recovery" && nativeUrl && nativeSha) {
    return {
      route: selected,
      steps: [
        {
          type: "local_buildkit_preflight",
          source_repository: strategy.source_repository ?? null,
          source_ref: strategy.source_ref ?? null,
          platforms: ["linux/amd64", "linux/arm64"],
          push: false,
          load_current_platform_only: true,
          registry_secret_required: false,
        },
        { type: "download_verified_installer", url: nativeUrl, sha256: nativeSha, maximum_bytes: 1_048_576 },
        { type: "execute_verified_installer", executable: "bash", args: ["<verified_download_path>"], shell: false },
      ],
    };
  }
  if (selected === "native_verified_installer_only" && nativeUrl && nativeSha) {
    return {
      route: selected,
      steps: [
        { type: "download_verified_installer", url: nativeUrl, sha256: nativeSha, maximum_bytes: 1_048_576 },
        { type: "execute_verified_installer", executable: "bash", args: ["<verified_download_path>"], shell: false },
      ],
    };
  }
  if (selected === "supabase_edge_queue") {
    return { route: selected, steps: [{ type: "preserve_request_in_supabase_queue", shell: false }] };
  }
  return { route: "blocked_no_safe_route", steps: [] };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return fail("method_not_allowed", 405);
  if (!SUPABASE_URL || !ADMIN_KEY || !PUBLISHABLE_KEY) return fail("server_not_configured", 503);

  let body: JsonRecord;
  try {
    body = await bodyObject(req);
  } catch (response) {
    return response instanceof Response ? response : fail("invalid_request", 400);
  }

  const session = await authenticate(req, body);
  if (!session) return fail("pi_session_refresh_required", 401);

  const executionKey = bounded(body.execution_key ?? req.headers.get("x-execution-key"), 1, 128);
  const correlationId = bounded(body.correlation_id ?? req.headers.get("x-correlation-id"), 1, 128);
  if (!executionKey) return fail("execution_key_required", 400);

  const hostOs = (bounded(body.host_os, 1, 32) ?? "linux").toLowerCase();
  const hostArch = normalizeArch(bounded(body.host_arch, 1, 32) ?? "unknown");
  const hostBits = integer(body.host_bits, 16, 128) ?? 0;
  const memoryMb = body.memory_mb === null || body.memory_mb === undefined
    ? null
    : integer(body.memory_mb, 1, 1_048_576);
  const diskMb = body.runtime_disk_free_mb === null || body.runtime_disk_free_mb === undefined
    ? null
    : integer(body.runtime_disk_free_mb, 0, 1_073_741_824);
  const dockerPresent = body.docker_present === true;
  const registryPullAvailable = body.registry_pull_available === true;
  const buildxPresent = body.buildx_present === true;
  const dockerEngineVersion = bounded(body.docker_engine_version, 1, 80);

  if (!hostArch || !hostBits ||
      (body.memory_mb !== null && body.memory_mb !== undefined && memoryMb === null) ||
      (body.runtime_disk_free_mb !== null && body.runtime_disk_free_mb !== undefined && diskMb === null)) {
    return fail("invalid_runtime_fingerprint", 400);
  }

  const { data: existing } = await admin.from("bridge_request_ledger")
    .select("allowed,reason")
    .eq("user_id", session.user.id)
    .eq("action", "container_bootstrap")
    .eq("execution_key", executionKey)
    .maybeSingle();
  if (existing) return fail("duplicate_execution_key", 409);

  const resolverDockerAvailable = dockerPresent && (registryPullAvailable || buildxPresent);
  const { data: strategy, error: strategyError } = await admin.rpc(
    "bridge_resolve_runtime_compatibility",
    {
      p_component_key: "openclaw.recovery",
      p_host_os: hostOs,
      p_host_arch: hostArch,
      p_host_bits: hostBits,
      p_memory_mb: memoryMb,
      p_runtime_disk_free_mb: diskMb,
      p_docker_present: resolverDockerAvailable,
      p_registry_pull_available: registryPullAvailable,
    },
  );
  if (strategyError || !strategy || typeof strategy !== "object") return fail("compatibility_resolver_failed", 503);

  const result = strategy as JsonRecord;
  const allowed = result.selected_strategy !== "blocked_no_safe_route";
  await admin.from("bridge_request_ledger").insert({
    user_id: session.user.id,
    action: "container_bootstrap",
    execution_key: executionKey,
    allowed,
    duplicate: false,
    reason: String(result.selected_strategy ?? "unknown"),
  });

  const policy = await loadRuntimePolicy();
  const { data: credentials } = await admin.from("bridge_credentials")
    .select("integration,configured,validation_status,runtime_presence")
    .in("integration", ["docker_hub", "docker"]);
  const dockerCredential = (credentials ?? []).find((row) => row.integration === "docker_hub") ??
    (credentials ?? []).find((row) => row.integration === "docker") ?? null;

  await admin.from("bridge_runtime_compatibility_observations").insert({
    component_key: "openclaw.recovery",
    node_name: bounded(body.node_name, 1, 120) ?? "raspberry-pi5",
    correlation_id: correlationId,
    host_os: hostOs,
    host_arch: hostArch,
    host_bits: hostBits,
    memory_mb: memoryMb,
    runtime_disk_free_mb: diskMb,
    docker_present: dockerPresent,
    registry_pull_available: registryPullAvailable,
    selected_strategy: String(result.selected_strategy),
    result: String(result.result),
    detail: {
      buildx_present: buildxPresent,
      resolver_docker_available: resolverDockerAvailable,
      docker_engine_version_present: Boolean(dockerEngineVersion),
      session_refreshed: session.refreshed,
      image_digest_pinned: Boolean(result.prebuilt_digest),
      provider_secret_returned: false,
      docker_registry_secret_returned: false,
      secret_values_included: false,
    },
  });

  const sessionPayload = session.refreshed ? {
    access_token: session.accessToken,
    refresh_token: session.refreshToken,
    expires_in: session.expiresIn,
    role: "pi-gateway-client",
  } : null;
  const registryOrder = Array.isArray(policy.registry_order)
    ? policy.registry_order.filter((item): item is string => typeof item === "string")
    : ["docker_hub_public", "local_buildkit", "native_verified_installer", "supabase_edge_queue"];
  const plan = typedExecutionPlan(result, policy, hostArch);

  return reply({
    ok: true,
    version: 3,
    allowed,
    session: sessionPayload,
    auth_session_returned: Boolean(sessionPayload),
    runtime_fingerprint: {
      host_os: hostOs,
      host_arch: hostArch,
      host_bits: hostBits,
      memory_mb: memoryMb,
      runtime_disk_free_mb: diskMb,
      docker_present: dockerPresent,
      buildx_present: buildxPresent,
      docker_engine_version_present: Boolean(dockerEngineVersion),
      registry_pull_available: registryPullAvailable,
      resolver_docker_available: resolverDockerAvailable,
    },
    strategy: result,
    execution_plan: plan,
    registry: {
      order: registryOrder,
      preferred: "docker_hub",
      prebuilt_image: result.prebuilt_image ?? policy.prebuilt_image ?? null,
      prebuilt_digest: result.prebuilt_digest ?? policy.prebuilt_digest ?? null,
      image_by_digest: policy.image_by_digest ?? null,
      docker_hub_repository: policy.docker_hub_repository ?? null,
      docker_hub_visibility: policy.docker_hub_visibility ?? null,
      docker_hub_runtime_pull_auth: policy.docker_hub_runtime_pull_auth ?? "anonymous",
      docker_hub_publisher_auth: policy.docker_hub_publisher_auth ?? "supabase_edge_pat",
      docker_hub_enabled: policy.docker_hub_mirror === true,
      docker_hub_secret_present: dockerCredential?.configured === true,
      docker_hub_secret_status: dockerCredential?.validation_status ?? "unknown",
      docker_hub_secret_selected: dockerCredential?.runtime_presence?.selected === true ||
        dockerCredential?.runtime_presence?.publisher_enabled === true,
      docker_registry_secret_returned: false,
    },
    runtime_security: {
      docker_socket_mount: false,
      privileged_container: false,
      host_pid_namespace: false,
      provider_secret_in_image: false,
      provider_secret_mount: false,
      registry_secret_mount: false,
      read_only_rootfs: true,
      network_default: "none",
      run_as_non_root: true,
      second_telegram_poller: false,
      paid_api_fallback: false,
    },
    host_native_exceptions: [
      "tailscale_tun",
      "systemd_service_management",
      "usb_devices",
      "gpio",
      "gpu_driver",
      "single_telegram_poller",
    ],
    provider_secret_returned: false,
    docker_registry_secret_returned: false,
    secret_values_included: Boolean(sessionPayload),
  });
});
