import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.56.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const WORKER = "supabase-pattern-research-worker-v1";
const MAX_TASKS = 2;
const MAX_GITHUB_RESULTS = 5;
const ALLOWED_PROVIDERS = ["github", "internal_catalog"] as const;

type KeyMap = Record<string, string>;
type JsonRecord = Record<string, unknown>;
type ResearchTask = {
  research_id: string;
  candidate_id: string;
  provider: "github" | "internal_catalog";
  english_query: string;
  priority: number;
  attempts: number;
  max_attempts: number;
};
type Candidate = {
  candidate_id: string;
  canonical_title: string;
  english_query: string | null;
  fingerprint: string;
  priority_score: number;
  risk_score: number;
};
type GitHubRepository = {
  full_name?: string;
  html_url?: string;
  description?: string | null;
  stargazers_count?: number;
  forks_count?: number;
  archived?: boolean;
  pushed_at?: string | null;
  updated_at?: string | null;
  default_branch?: string | null;
  language?: string | null;
  topics?: string[];
  license?: { spdx_id?: string | null; name?: string | null } | null;
};

function parseNamed(raw: string | undefined): KeyMap {
  if (!raw) return {};
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter(([, item]) =>
        typeof item === "string" && item.length > 0
      ),
    ) as KeyMap;
  } catch {
    return {};
  }
}

const secretSet = parseNamed(Deno.env.get("SUPABASE_SECRET_KEYS"));
const adminKey = secretSet.default ?? Object.values(secretSet)[0] ??
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const admin = createClient(SUPABASE_URL, adminKey, {
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

async function sha256(value: string): Promise<string> {
  const input = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    Uint8Array.from(input).buffer,
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function safeError(error: unknown): string {
  return (error instanceof Error ? error.message : "research_failed")
    .replace(/[^A-Za-z0-9_.:-]+/g, "_")
    .slice(0, 200);
}

function keywords(value: string): string[] {
  const stop = new Set([
    "official",
    "documentation",
    "repository",
    "implementation",
    "maintained",
    "workflow",
    "using",
    "with",
    "from",
    "that",
    "this",
    "into",
    "find",
    "open",
    "source",
    "requirements",
    "free",
    "preferred",
    "existing",
  ]);
  return [...new Set(
    value.toLowerCase()
      .replace(/[^a-z0-9+._-]+/g, " ")
      .split(/\s+/)
      .map((word) => word.trim())
      .filter((word) => word.length >= 3 && !stop.has(word)),
  )].slice(0, 12);
}

function githubQuery(candidate: Candidate): string {
  const terms = keywords(
    `${candidate.canonical_title} ${candidate.english_query ?? ""}`,
  ).slice(0, 6);
  const base = terms.length
    ? terms.join(" ")
    : candidate.canonical_title.slice(0, 80);
  return `${base} in:name,description archived:false`.slice(0, 240);
}

function maintenanceScore(
  pushedAt: string | null | undefined,
  archived: boolean | undefined,
): number {
  if (archived) return 10;
  if (!pushedAt) return 40;
  const ageDays = Math.max(
    0,
    (Date.now() - new Date(pushedAt).getTime()) / 86_400_000,
  );
  if (ageDays <= 30) return 95;
  if (ageDays <= 90) return 85;
  if (ageDays <= 365) return 70;
  if (ageDays <= 730) return 50;
  return 30;
}

function securityScore(
  license: string | null,
  archived: boolean | undefined,
): number {
  if (archived) return 25;
  const normalized = (license ?? "").toUpperCase();
  if (
    [
      "MIT",
      "APACHE-2.0",
      "BSD-2-CLAUSE",
      "BSD-3-CLAUSE",
      "ISC",
      "POSTGRESQL",
    ].includes(normalized)
  ) return 85;
  if (
    [
      "MPL-2.0",
      "LGPL-2.1",
      "LGPL-2.1-OR-LATER",
      "GPL-3.0",
      "AGPL-3.0",
    ].includes(normalized)
  ) return 65;
  return 50;
}

function compatibilityScore(repository: GitHubRepository): number {
  const haystack = [
    repository.description ?? "",
    repository.language ?? "",
    ...(repository.topics ?? []),
  ].join(" ").toLowerCase();
  let score = 55;
  if (/arm64|aarch64|raspberry|docker|oci|linux/.test(haystack)) score += 20;
  if (/api|webhook|mcp|workflow|queue|retry|postgres|supabase/.test(haystack)) {
    score += 15;
  }
  if (repository.archived) score -= 35;
  return Math.max(0, Math.min(100, score));
}

async function authenticate(req: Request): Promise<boolean> {
  const token = req.headers.get("x-pattern-research-token")?.trim() ?? "";
  if (token.length < 20) return false;
  const tokenHash = await sha256(token);
  const { data, error } = await admin.rpc(
    "bridge_verify_pattern_research_worker_token",
    { p_token_hash: tokenHash },
  );
  return !error && data === true;
}

async function selectedGitHubToken(): Promise<{
  alias: string;
  token: string;
} | null> {
  const { data, error } = await admin.from("bridge_credentials")
    .select("canonical_secret_name,configured,validation_status")
    .eq("integration", "github")
    .maybeSingle();
  if (error || !data?.configured || data.validation_status !== "valid") {
    return null;
  }
  const alias = typeof data.canonical_secret_name === "string"
    ? data.canonical_secret_name
    : "";
  const token = alias ? Deno.env.get(alias)?.trim() ?? "" : "";
  return alias && token ? { alias, token } : null;
}

async function claim(): Promise<ResearchTask | null> {
  const { data, error } = await admin.rpc(
    "bridge_claim_research_task_for_provider",
    {
      p_worker: WORKER,
      p_providers: [...ALLOWED_PROVIDERS],
      p_lease_minutes: 10,
    },
  );
  if (error || !Array.isArray(data) || !data[0]) return null;
  return data[0] as ResearchTask;
}

async function loadCandidate(candidateId: string): Promise<Candidate> {
  const { data, error } = await admin.from("bridge_pattern_candidates")
    .select(
      "candidate_id,canonical_title,english_query,fingerprint,priority_score,risk_score",
    )
    .eq("candidate_id", candidateId)
    .single();
  if (error || !data) throw new Error("candidate_not_found");
  return data as Candidate;
}

async function upsertMatch(
  candidateId: string,
  solutionId: string,
  matchScore: number,
  rationale: string,
  evidence: JsonRecord,
): Promise<void> {
  const { error } = await admin.from("bridge_pattern_solution_matches").upsert({
    candidate_id: candidateId,
    solution_id: solutionId,
    match_score: Math.max(0, Math.min(100, matchScore)),
    status: "candidate",
    rationale: rationale.slice(0, 1000),
    evidence: { ...evidence, secret_values_included: false },
    secret_values_included: false,
    updated_at: new Date().toISOString(),
  }, { onConflict: "candidate_id,solution_id" });
  if (error) throw new Error("solution_match_upsert_failed");
}

async function internalCatalogResearch(
  task: ResearchTask,
  candidate: Candidate,
): Promise<JsonRecord> {
  const { data, error } = await admin.from("bridge_solution_catalog")
    .select(
      "solution_id,solution_key,title,source_type,repository,license_spdx,status,capabilities,maintenance_score,compatibility_score,security_score",
    )
    .in("status", ["selected", "reviewed", "discovered"])
    .limit(200);
  if (error) throw new Error("internal_catalog_read_failed");

  const wanted = keywords(
    `${candidate.canonical_title} ${candidate.english_query ?? ""}`,
  );
  const ranked = (data ?? []).map((row: any) => {
    const text = `${row.solution_key} ${row.title} ${row.source_type} ${
      row.repository ?? ""
    } ${JSON.stringify(row.capabilities ?? [])}`.toLowerCase();
    const matches = wanted.filter((word) => text.includes(word));
    let score = matches.length * 12;
    if (row.status === "selected") score += 25;
    else if (row.status === "reviewed") score += 15;
    score += Math.round(Number(row.maintenance_score ?? 50) * 0.08);
    score += Math.round(Number(row.compatibility_score ?? 50) * 0.08);
    score += Math.round(Number(row.security_score ?? 50) * 0.08);
    return {
      row,
      score: Math.max(0, Math.min(100, score)),
      matches,
    };
  }).filter((entry) => entry.score >= 28)
    .sort((left, right) => right.score - left.score)
    .slice(0, 5);

  for (const entry of ranked) {
    await upsertMatch(
      candidate.candidate_id,
      entry.row.solution_id,
      entry.score,
      `Internal catalog match on ${
        entry.matches.join(", ") || "reviewed source"
      }.`,
      {
        provider: "internal_catalog",
        research_id: task.research_id,
        matched_keywords: entry.matches,
        source_status: entry.row.status,
      },
    );
  }

  return {
    provider: "internal_catalog",
    result_count: ranked.length,
    matched_solution_keys: ranked.map((entry) => entry.row.solution_key),
    automatic_selection: false,
    automatic_install: false,
    secret_values_included: false,
  };
}

async function githubResearch(
  task: ResearchTask,
  candidate: Candidate,
): Promise<JsonRecord> {
  const credential = await selectedGitHubToken();
  if (!credential) throw new Error("github_readonly_credential_not_ready");
  const query = githubQuery(candidate);
  const url = new URL("https://api.github.com/search/repositories");
  url.searchParams.set("q", query);
  url.searchParams.set("sort", "stars");
  url.searchParams.set("order", "desc");
  url.searchParams.set("per_page", String(MAX_GITHUB_RESULTS));

  const response = await fetch(url, {
    headers: {
      authorization: `Bearer ${credential.token}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      "user-agent": "supabase-openclaw-pattern-research/1",
    },
    signal: AbortSignal.timeout(20_000),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 403 || response.status === 429) {
      throw new Error("github_search_rate_limited");
    }
    throw new Error(`github_search_http_${response.status}`);
  }

  const repositories = Array.isArray(data?.items)
    ? data.items as GitHubRepository[]
    : [];
  let stored = 0;
  const solutionKeys: string[] = [];
  for (const repository of repositories.slice(0, MAX_GITHUB_RESULTS)) {
    const fullName = typeof repository.full_name === "string"
      ? repository.full_name
      : "";
    const htmlUrl = typeof repository.html_url === "string"
      ? repository.html_url
      : "";
    if (!fullName || !htmlUrl || repository.archived === true) continue;

    const solutionKey = `github:${fullName.toLowerCase()}`;
    const license = repository.license?.spdx_id &&
        repository.license.spdx_id !== "NOASSERTION"
      ? repository.license.spdx_id
      : null;
    const maintenance = maintenanceScore(
      repository.pushed_at,
      repository.archived,
    );
    const compatibility = compatibilityScore(repository);
    const security = securityScore(license, repository.archived);
    const supportedPlatforms = compatibility >= 70
      ? ["linux/arm64", "linux/amd64"]
      : [];

    const { data: existing, error: existingError } = await admin.from(
      "bridge_solution_catalog",
    ).select("solution_id,status").eq("solution_key", solutionKey)
      .maybeSingle();
    if (existingError) throw new Error("github_solution_lookup_failed");

    let solutionId = existing?.solution_id as string | undefined;
    if (!solutionId) {
      const { data: inserted, error: insertError } = await admin.from(
        "bridge_solution_catalog",
      ).insert({
        candidate_id: null,
        solution_key: solutionKey,
        source_type: "github_repository",
        title: fullName,
        source_url: htmlUrl,
        repository: htmlUrl,
        version_ref: repository.default_branch ?? null,
        license_spdx: license,
        maintenance_score: maintenance,
        compatibility_score: compatibility,
        security_score: security,
        implementation_cost_score: 50,
        capabilities: repository.topics ?? [],
        supported_platforms: supportedPlatforms,
        evidence: {
          stars: Number(repository.stargazers_count ?? 0),
          forks: Number(repository.forks_count ?? 0),
          language: repository.language ?? null,
          pushed_at: repository.pushed_at ?? null,
          updated_at: repository.updated_at ?? null,
          archived: false,
          github_metadata_only: true,
          repository_content_downloaded: false,
          readme_executed: false,
          research_id: task.research_id,
          secret_values_included: false,
        },
        status: "discovered",
        secret_values_included: false,
        discovered_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      }).select("solution_id").single();
      if (insertError || !inserted?.solution_id) {
        throw new Error("github_solution_insert_failed");
      }
      solutionId = inserted.solution_id as string;
    } else {
      const { error: updateError } = await admin.from(
        "bridge_solution_catalog",
      ).update({
        title: fullName,
        source_url: htmlUrl,
        repository: htmlUrl,
        version_ref: repository.default_branch ?? null,
        license_spdx: license,
        maintenance_score: maintenance,
        compatibility_score: compatibility,
        security_score: security,
        capabilities: repository.topics ?? [],
        supported_platforms: supportedPlatforms,
        evidence: {
          stars: Number(repository.stargazers_count ?? 0),
          forks: Number(repository.forks_count ?? 0),
          language: repository.language ?? null,
          pushed_at: repository.pushed_at ?? null,
          updated_at: repository.updated_at ?? null,
          archived: false,
          github_metadata_only: true,
          repository_content_downloaded: false,
          readme_executed: false,
          research_id: task.research_id,
          existing_review_state_preserved: true,
          secret_values_included: false,
        },
        secret_values_included: false,
        updated_at: new Date().toISOString(),
      }).eq("solution_id", solutionId);
      if (updateError) throw new Error("github_solution_update_failed");
    }

    const candidateWords = keywords(
      `${candidate.canonical_title} ${candidate.english_query ?? ""}`,
    );
    const repositoryText = `${fullName} ${repository.description ?? ""} ${
      (repository.topics ?? []).join(" ")
    }`.toLowerCase();
    const matchedWords = candidateWords.filter((word) =>
      repositoryText.includes(word)
    );
    const matchScore = Math.min(
      100,
      matchedWords.length * 12 +
        Math.round(maintenance * 0.15) +
        Math.round(compatibility * 0.15) +
        Math.round(security * 0.10),
    );
    await upsertMatch(
      candidate.candidate_id,
      solutionId,
      matchScore,
      `GitHub repository metadata matched ${
        matchedWords.join(", ") || "the bounded search query"
      }.`,
      {
        provider: "github",
        research_id: task.research_id,
        matched_keywords: matchedWords,
        search_query_sha256: await sha256(query),
        repository_content_downloaded: false,
        readme_executed: false,
      },
    );
    stored += 1;
    solutionKeys.push(solutionKey);
  }

  return {
    provider: "github",
    result_count: stored,
    solution_keys: solutionKeys,
    selected_credential_alias: credential.alias,
    query_sha256: await sha256(query),
    repository_content_downloaded: false,
    readme_executed: false,
    automatic_selection: false,
    automatic_install: false,
    secret_values_included: false,
  };
}

async function complete(
  task: ResearchTask,
  summary: JsonRecord,
): Promise<void> {
  const { error } = await admin.rpc("bridge_complete_research_task", {
    p_research_id: task.research_id,
    p_worker: WORKER,
    p_result_count: Number(summary.result_count ?? 0),
    p_result_summary: summary,
  });
  if (error) throw new Error("research_task_complete_failed");
}

async function fail(task: ResearchTask, errorCode: string): Promise<void> {
  const retrySeconds = errorCode === "github_search_rate_limited" ? 3600 : 900;
  await admin.rpc("bridge_fail_research_task", {
    p_research_id: task.research_id,
    p_worker: WORKER,
    p_error_code: errorCode,
    p_retry_seconds: retrySeconds,
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return reply({ ok: false, error: "method_not_allowed" }, 405);
  }
  if (!SUPABASE_URL || !adminKey) {
    return reply(
      { ok: false, error: "server_not_configured", secret_values_included: false },
      503,
    );
  }
  if (!await authenticate(req)) {
    return reply(
      { ok: false, error: "unauthorized", secret_values_included: false },
      401,
    );
  }

  const { data: requeued } = await admin.rpc(
    "bridge_requeue_expired_research_tasks",
  );
  const results: JsonRecord[] = [];
  let claimed = 0;
  let completed = 0;
  let failedCount = 0;

  for (let index = 0; index < MAX_TASKS; index += 1) {
    const task = await claim();
    if (!task) break;
    claimed += 1;
    try {
      const candidate = await loadCandidate(task.candidate_id);
      const summary = task.provider === "github"
        ? await githubResearch(task, candidate)
        : await internalCatalogResearch(task, candidate);
      await complete(task, summary);
      completed += 1;
      results.push({
        research_id: task.research_id,
        provider: task.provider,
        state: "completed",
        ...summary,
      });
    } catch (error) {
      const code = safeError(error);
      await fail(task, code);
      failedCount += 1;
      results.push({
        research_id: task.research_id,
        provider: task.provider,
        state: "requeued_or_failed",
        error_code: code,
        secret_values_included: false,
      });
    }
  }

  await admin.from("bridge_events").insert({
    event_type: "pattern_research_worker_run",
    node_name: "supabase",
    correlation_id: crypto.randomUUID(),
    severity: failedCount > 0 ? "warning" : "info",
    outcome: "succeeded",
    detail: {
      worker: WORKER,
      expired_leases_requeued: Number(requeued ?? 0),
      claimed,
      completed,
      failed: failedCount,
      providers: [...ALLOWED_PROVIDERS],
      github_metadata_only: true,
      repository_content_downloaded: false,
      readme_executed: false,
      automatic_install: false,
      automatic_skill_activation: false,
      secret_values_included: false,
    },
    created_at: new Date().toISOString(),
  });

  return reply({
    ok: true,
    expired_leases_requeued: Number(requeued ?? 0),
    claimed,
    completed,
    failed: failedCount,
    results,
    providers: [...ALLOWED_PROVIDERS],
    github_metadata_only: true,
    repository_content_downloaded: false,
    readme_executed: false,
    automatic_install: false,
    automatic_skill_activation: false,
    provider_secret_returned: false,
    secret_values_included: false,
  });
});
