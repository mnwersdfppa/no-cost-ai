begin;

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.bridge_pattern_observations (
  observation_id uuid primary key default gen_random_uuid(),
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
  source_type text not null check (source_type in (
    'supabase_event','completion_gate','work_queue','pi','openclaw','telegram',
    'github','notion','n8n','docker','mcp','manual','other'
  )),
  source_ref text,
  source_ref_key text generated always as (coalesce(source_ref,'')) stored,
  pattern_kind text not null check (pattern_kind in (
    'error','repeated_reasoning','workflow','latency','cost','compatibility',
    'credential','availability','data_quality','security','other'
  )),
  canonical_title text not null check (char_length(canonical_title) between 3 and 240),
  redacted_summary text not null check (char_length(redacted_summary) between 3 and 4000),
  error_code text,
  context jsonb not null default '{}'::jsonb,
  occurrence_count integer not null default 1 check (occurrence_count between 1 and 1000000000),
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  estimated_reasoning_tokens integer not null default 0 check (estimated_reasoning_tokens between 0 and 10000000),
  estimated_recovery_seconds integer not null default 0 check (estimated_recovery_seconds between 0 and 31536000),
  user_impact smallint not null default 50 check (user_impact between 0 and 100),
  automation_fit smallint not null default 50 check (automation_fit between 0 and 100),
  reversibility smallint not null default 50 check (reversibility between 0 and 100),
  confidence smallint not null default 50 check (confidence between 0 and 100),
  security_risk smallint not null default 20 check (security_risk between 0 and 100),
  redaction_applied boolean not null default true,
  secret_values_included boolean not null default false check (secret_values_included=false),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (last_seen >= first_seen)
);

create unique index if not exists bridge_pattern_observation_dedupe_idx
  on public.bridge_pattern_observations(fingerprint,source_type,source_ref_key);
create index if not exists bridge_pattern_observations_recent_idx
  on public.bridge_pattern_observations(last_seen desc,occurrence_count desc);
create index if not exists bridge_pattern_observations_kind_idx
  on public.bridge_pattern_observations(pattern_kind,last_seen desc);

create table if not exists public.bridge_pattern_candidates (
  candidate_id uuid primary key default gen_random_uuid(),
  fingerprint text not null unique check (fingerprint ~ '^[0-9a-f]{64}$'),
  canonical_title text not null,
  english_query text,
  translation_state text not null default 'pending' check (translation_state in ('pending','ready','verified','blocked')),
  state text not null default 'observed' check (state in (
    'observed','translation_pending','ready_for_research','researching','solution_found',
    'skill_proposed','skill_active','deferred','blocked'
  )),
  total_occurrences bigint not null default 0 check (total_occurrences >= 0),
  source_count integer not null default 0 check (source_count >= 0),
  first_seen timestamptz,
  last_seen timestamptz,
  frequency_score numeric(5,2) not null default 0 check (frequency_score between 0 and 100),
  recency_score numeric(5,2) not null default 0 check (recency_score between 0 and 100),
  impact_score numeric(5,2) not null default 0 check (impact_score between 0 and 100),
  reasoning_cost_score numeric(5,2) not null default 0 check (reasoning_cost_score between 0 and 100),
  automation_fit_score numeric(5,2) not null default 0 check (automation_fit_score between 0 and 100),
  reversibility_score numeric(5,2) not null default 0 check (reversibility_score between 0 and 100),
  confidence_score numeric(5,2) not null default 0 check (confidence_score between 0 and 100),
  risk_score numeric(5,2) not null default 0 check (risk_score between 0 and 100),
  priority_score numeric(6,2) not null default 0 check (priority_score between 0 and 100),
  evidence_refs jsonb not null default '[]'::jsonb,
  selected_skill_key text,
  blocked_reason text,
  scoring_version integer not null default 1,
  scored_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists bridge_pattern_candidates_priority_idx
  on public.bridge_pattern_candidates(state,priority_score desc,last_seen desc);

create table if not exists public.bridge_research_queue (
  research_id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.bridge_pattern_candidates(candidate_id) on delete cascade,
  provider text not null check (provider in (
    'official_docs','github','mcp_registry','n8n_templates','docker_hub','internal_catalog','manual'
  )),
  english_query text not null check (char_length(english_query) between 8 and 1000),
  query_hash text not null check (query_hash ~ '^[0-9a-f]{64}$'),
  state text not null default 'queued' check (state in ('queued','claimed','completed','failed','blocked')),
  priority smallint not null default 50 check (priority between 0 and 100),
  attempts integer not null default 0 check (attempts between 0 and 20),
  max_attempts integer not null default 5 check (max_attempts between 1 and 20),
  not_before timestamptz not null default now(),
  lease_until timestamptz,
  claimed_by text,
  result_count integer not null default 0 check (result_count >= 0),
  last_error text,
  secret_values_included boolean not null default false check (secret_values_included=false),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(candidate_id,provider,query_hash)
);

create index if not exists bridge_research_queue_claim_idx
  on public.bridge_research_queue(state,not_before,priority desc,created_at)
  where state='queued';

create table if not exists public.bridge_solution_catalog (
  solution_id uuid primary key default gen_random_uuid(),
  candidate_id uuid references public.bridge_pattern_candidates(candidate_id) on delete set null,
  solution_key text not null unique,
  source_type text not null check (source_type in (
    'official_api','official_docs','github_repository','mcp_server','n8n_template',
    'docker_image','langgraph_pattern','langsmith_pattern','internal_existing','other'
  )),
  title text not null,
  source_url text,
  repository text,
  version_ref text,
  license_spdx text,
  maintenance_score smallint not null default 50 check (maintenance_score between 0 and 100),
  compatibility_score smallint not null default 50 check (compatibility_score between 0 and 100),
  security_score smallint not null default 50 check (security_score between 0 and 100),
  implementation_cost_score smallint not null default 50 check (implementation_cost_score between 0 and 100),
  capabilities jsonb not null default '[]'::jsonb,
  supported_platforms text[] not null default array[]::text[],
  evidence jsonb not null default '{}'::jsonb,
  status text not null default 'discovered' check (status in (
    'discovered','reviewed','selected','rejected','superseded'
  )),
  rejection_reason text,
  secret_values_included boolean not null default false check (secret_values_included=false),
  discovered_at timestamptz not null default now(),
  reviewed_at timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists bridge_solution_catalog_candidate_idx
  on public.bridge_solution_catalog(candidate_id,status,security_score desc,compatibility_score desc);

create table if not exists public.bridge_skill_registry (
  skill_key text primary key check (skill_key ~ '^[a-z0-9][a-z0-9._-]{2,119}$'),
  display_name text not null,
  category text not null check (category in (
    'validation','deduplication','retry','cache','classification','read_only_api',
    'schema_check','health_check','reporting','compatibility','migration','host_control',
    'credential','network','deployment','other'
  )),
  description text not null,
  source_solution_id uuid references public.bridge_solution_catalog(solution_id) on delete set null,
  state text not null default 'observed' check (state in (
    'observed','proposed','sandboxed','validated','canary','active','deprecated','blocked'
  )),
  risk_tier text not null default 'low' check (risk_tier in ('low','medium','high','critical')),
  auto_promotable boolean not null default false,
  current_version integer not null default 0 check (current_version >= 0),
  trigger_policy jsonb not null default '{}'::jsonb,
  input_schema jsonb not null default '{}'::jsonb,
  output_schema jsonb not null default '{}'::jsonb,
  permissions jsonb not null default '[]'::jsonb,
  required_gates text[] not null default array['static_security','deterministic_e2e','rollback']::text[],
  rollback_strategy jsonb not null default '{}'::jsonb,
  owner_component text,
  canary_started_at timestamptz,
  activated_at timestamptz,
  deprecated_at timestamptz,
  blocked_reason text,
  secret_values_included boolean not null default false check (secret_values_included=false),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists bridge_skill_registry_state_idx
  on public.bridge_skill_registry(state,risk_tier,auto_promotable,updated_at desc);

create table if not exists public.bridge_skill_versions (
  skill_version_id uuid primary key default gen_random_uuid(),
  skill_key text not null references public.bridge_skill_registry(skill_key) on delete cascade,
  version integer not null check (version > 0),
  semantic_version text,
  definition jsonb not null,
  source_ref text,
  source_sha256 text check (source_sha256 is null or source_sha256 ~ '^[0-9a-f]{64}$'),
  status text not null default 'draft' check (status in ('draft','candidate','canary','active','retired','blocked')),
  immutable boolean not null default true,
  created_by text not null default 'system',
  secret_values_included boolean not null default false check (secret_values_included=false),
  created_at timestamptz not null default now(),
  unique(skill_key,version)
);

create table if not exists public.bridge_skill_evaluations (
  evaluation_id uuid primary key default gen_random_uuid(),
  skill_key text not null references public.bridge_skill_registry(skill_key) on delete cascade,
  version integer not null,
  evaluation_type text not null check (evaluation_type in (
    'static_security','schema_validation','deterministic_e2e','rollback','cost','latency',
    'compatibility','secret_boundary','canary','manual_review'
  )),
  passed boolean not null,
  score numeric(5,2) check (score is null or score between 0 and 100),
  evidence_ref text,
  evidence jsonb not null default '{}'::jsonb,
  evaluator text not null default 'system',
  secret_values_included boolean not null default false check (secret_values_included=false),
  evaluated_at timestamptz not null default now(),
  unique(skill_key,version,evaluation_type,evaluator,evaluated_at)
);

create index if not exists bridge_skill_evaluations_gate_idx
  on public.bridge_skill_evaluations(skill_key,version,evaluation_type,evaluated_at desc);

create table if not exists public.bridge_automation_runs (
  run_id uuid primary key default gen_random_uuid(),
  skill_key text not null references public.bridge_skill_registry(skill_key),
  skill_version integer not null,
  execution_key text not null,
  trigger_type text not null,
  state text not null check (state in ('admitted','running','succeeded','failed','rolled_back','blocked','duplicate')),
  input_fingerprint text check (input_fingerprint is null or input_fingerprint ~ '^[0-9a-f]{64}$'),
  result_summary jsonb not null default '{}'::jsonb,
  error_code text,
  latency_ms integer check (latency_ms is null or latency_ms >= 0),
  tokens_saved_estimate integer not null default 0 check (tokens_saved_estimate >= 0),
  reasoning_steps_avoided integer not null default 0 check (reasoning_steps_avoided >= 0),
  rollback_performed boolean not null default false,
  secret_values_included boolean not null default false check (secret_values_included=false),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(skill_key,execution_key)
);

create index if not exists bridge_automation_runs_recent_idx
  on public.bridge_automation_runs(skill_key,started_at desc,state);

create table if not exists public.bridge_source_bindings (
  binding_id uuid primary key default gen_random_uuid(),
  source_system text not null check (source_system in ('notion','github','supabase','obsidian','n8n','other')),
  source_object_id text not null,
  source_title text,
  destination_type text not null check (destination_type in (
    'pattern','solution','skill','capability','knowledge','archive','ignored'
  )),
  destination_key text,
  migration_state text not null default 'discovered' check (migration_state in (
    'discovered','classified','staged','copied','verified','archived','blocked','ignored'
  )),
  content_fingerprint text check (content_fingerprint is null or content_fingerprint ~ '^[0-9a-f]{64}$'),
  classification jsonb not null default '{}'::jsonb,
  source_last_edited_at timestamptz,
  migrated_at timestamptz,
  verified_at timestamptz,
  secret_values_included boolean not null default false check (secret_values_included=false),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(source_system,source_object_id)
);

create table if not exists public.bridge_capability_registry (
  capability_key text primary key check (capability_key ~ '^[a-z0-9][a-z0-9._-]{2,159}$'),
  provider text not null,
  capability_type text not null check (capability_type in (
    'api','rpc','edge_function','mcp','webhook','cli','container','host_adapter','workflow','database'
  )),
  status text not null default 'discovered' check (status in (
    'discovered','connected','verified','selected','degraded','blocked','deprecated'
  )),
  endpoint_ref text,
  auth_location text,
  cost_tier text not null default 'free' check (cost_tier in ('free','included','metered','paid','unknown')),
  permissions jsonb not null default '[]'::jsonb,
  supported_platforms text[] not null default array[]::text[],
  use_cases jsonb not null default '[]'::jsonb,
  fallback_capability_keys text[] not null default array[]::text[],
  evidence jsonb not null default '{}'::jsonb,
  selected boolean not null default false,
  secret_values_included boolean not null default false check (secret_values_included=false),
  last_verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.bridge_touch_updated_at()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

DO $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'bridge_pattern_observations','bridge_pattern_candidates','bridge_research_queue',
    'bridge_solution_catalog','bridge_skill_registry','bridge_source_bindings',
    'bridge_capability_registry'
  ] loop
    execute format('drop trigger if exists %I on public.%I',v_table||'_touch_updated_at',v_table);
    execute format('create trigger %I before update on public.%I for each row execute function public.bridge_touch_updated_at()',v_table||'_touch_updated_at',v_table);
  end loop;
end $$;

DO $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'bridge_pattern_observations','bridge_pattern_candidates','bridge_research_queue',
    'bridge_solution_catalog','bridge_skill_registry','bridge_skill_versions',
    'bridge_skill_evaluations','bridge_automation_runs','bridge_source_bindings',
    'bridge_capability_registry'
  ] loop
    execute format('alter table public.%I enable row level security',v_table);
    execute format('revoke all on table public.%I from public,anon,authenticated',v_table);
    execute format('grant all on table public.%I to service_role',v_table);
  end loop;
end $$;

revoke all on function public.bridge_touch_updated_at() from public,anon,authenticated;
grant execute on function public.bridge_touch_updated_at() to service_role;

commit;
