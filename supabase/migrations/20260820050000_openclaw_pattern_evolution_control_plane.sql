begin;

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.bridge_pattern_observations (
  observation_id uuid primary key default gen_random_uuid(),
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
  source_type text not null,
  source_ref text,
  source_ref_key text generated always as (coalesce(source_ref,'')) stored,
  pattern_kind text not null,
  canonical_title text not null,
  redacted_summary text not null,
  error_code text,
  context jsonb not null default '{}'::jsonb,
  occurrence_count integer not null default 1 check (occurrence_count > 0),
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  estimated_reasoning_tokens integer not null default 0 check (estimated_reasoning_tokens >= 0),
  estimated_recovery_seconds integer not null default 0 check (estimated_recovery_seconds >= 0),
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

create table if not exists public.bridge_solution_catalog (
  solution_id uuid primary key default gen_random_uuid(),
  candidate_id uuid references public.bridge_pattern_candidates(candidate_id) on delete set null,
  solution_key text not null unique,
  source_type text not null,
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
  status text not null default 'discovered' check (status in ('discovered','reviewed','selected','rejected','superseded')),
  rejection_reason text,
  secret_values_included boolean not null default false check (secret_values_included=false),
  discovered_at timestamptz not null default now(),
  reviewed_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.bridge_research_queue (
  research_id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.bridge_pattern_candidates(candidate_id) on delete cascade,
  provider text not null,
  english_query text not null,
  query_hash text not null check (query_hash ~ '^[0-9a-f]{64}$'),
  state text not null default 'queued' check (state in ('queued','claimed','completed','failed','blocked')),
  priority smallint not null default 50 check (priority between 0 and 100),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 5 check (max_attempts between 1 and 20),
  not_before timestamptz not null default now(),
  lease_until timestamptz,
  claimed_by text,
  result_count integer not null default 0,
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

create table if not exists public.bridge_skill_registry (
  skill_key text primary key check (skill_key ~ '^[a-z0-9][a-z0-9._-]{2,119}$'),
  display_name text not null,
  category text not null,
  description text not null,
  source_solution_id uuid references public.bridge_solution_catalog(solution_id) on delete set null,
  state text not null default 'observed' check (state in ('observed','proposed','sandboxed','validated','canary','active','deprecated','blocked')),
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
  evaluation_type text not null,
  passed boolean not null,
  score numeric(5,2) check (score is null or score between 0 and 100),
  evidence_ref text,
  evidence jsonb not null default '{}'::jsonb,
  evaluator text not null default 'system',
  secret_values_included boolean not null default false check (secret_values_included=false),
  evaluated_at timestamptz not null default now()
);

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
  tokens_saved_estimate integer not null default 0,
  reasoning_steps_avoided integer not null default 0,
  rollback_performed boolean not null default false,
  secret_values_included boolean not null default false check (secret_values_included=false),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(skill_key,execution_key)
);

create table if not exists public.bridge_source_bindings (
  binding_id uuid primary key default gen_random_uuid(),
  source_system text not null,
  source_object_id text not null,
  source_title text,
  destination_type text not null,
  destination_key text,
  migration_state text not null default 'discovered',
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

create table if not exists public.openclaw_ssot_projection_queue (
  projection_id uuid primary key default gen_random_uuid(),
  projection_key text not null,
  target_system text not null,
  object_type text not null,
  source_ref text not null,
  canonical_payload jsonb not null,
  payload_hash text not null,
  status text not null default 'queued' check (status in ('queued','claimed','completed','failed','cancelled')),
  attempts integer not null default 0,
  max_attempts integer not null default 5,
  not_before timestamptz not null default now(),
  lease_until timestamptz,
  last_error text,
  projected_ref text,
  source_updated_at timestamptz,
  projected_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(target_system,projection_key,payload_hash)
);

create or replace function public.openclaw_enqueue_projection(
  p_projection_key text,
  p_target_system text,
  p_object_type text,
  p_source_ref text,
  p_canonical_payload jsonb,
  p_source_updated_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_hash text;
  v_id uuid;
begin
  if p_target_system not in ('notion','github','obsidian','human_report') then
    raise exception 'invalid_projection_target';
  end if;
  if p_canonical_payload is null or jsonb_typeof(p_canonical_payload)<>'object' then
    raise exception 'canonical_object_required';
  end if;
  if p_canonical_payload::text ~* '(sk-proj-|ghp_|github_pat_|tskey-|Bearer[[:space:]])' then
    raise exception 'secret_like_projection_rejected';
  end if;
  v_hash:=md5(p_canonical_payload::text);
  insert into public.openclaw_ssot_projection_queue(
    projection_key,target_system,object_type,source_ref,canonical_payload,payload_hash,
    source_updated_at,created_at,updated_at
  ) values (
    left(trim(p_projection_key),240),p_target_system,left(trim(p_object_type),120),
    left(trim(p_source_ref),500),p_canonical_payload,v_hash,p_source_updated_at,now(),now()
  )
  on conflict(target_system,projection_key,payload_hash) do update set
    source_updated_at=greatest(public.openclaw_ssot_projection_queue.source_updated_at,excluded.source_updated_at),
    updated_at=now()
  returning projection_id into v_id;
  return v_id;
end;
$$;

create or replace function public.bridge_pattern_skill_readiness()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $$
select jsonb_build_object(
  'state',case
    when exists(select 1 from public.bridge_skill_registry where state='blocked') then 'DEGRADED'
    when exists(select 1 from public.bridge_pattern_candidates where state in ('ready_for_research','researching','solution_found','skill_proposed')) then 'EVOLVING'
    else 'READY'
  end,
  'observations',(select count(*) from public.bridge_pattern_observations),
  'patterns',(select count(*) from public.bridge_pattern_candidates),
  'research_queue',jsonb_build_object(
    'queued',(select count(*) from public.bridge_research_queue where state='queued'),
    'claimed',(select count(*) from public.bridge_research_queue where state='claimed'),
    'completed',(select count(*) from public.bridge_research_queue where state='completed'),
    'failed',(select count(*) from public.bridge_research_queue where state='failed')
  ),
  'skills',jsonb_build_object(
    'proposed',(select count(*) from public.bridge_skill_registry where state='proposed'),
    'validated',(select count(*) from public.bridge_skill_registry where state='validated'),
    'canary',(select count(*) from public.bridge_skill_registry where state='canary'),
    'active',(select count(*) from public.bridge_skill_registry where state='active'),
    'blocked',(select count(*) from public.bridge_skill_registry where state='blocked')
  ),
  'policy',jsonb_build_object(
    'search_before_build',true,
    'automatic_high_risk_promotion',false,
    'arbitrary_code_execution',false,
    'credential_scope_auto_increase',false,
    'hidden_infrastructure',false,
    'audit_receipts_required',true,
    'rollback_required',true
  ),
  'secret_values_included',false,
  'generated_at',now()
);
$$;

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'bridge_pattern_observations','bridge_pattern_candidates','bridge_solution_catalog',
    'bridge_research_queue','bridge_skill_registry','bridge_skill_versions',
    'bridge_skill_evaluations','bridge_automation_runs','bridge_source_bindings',
    'openclaw_ssot_projection_queue'
  ] loop
    execute format('alter table public.%I enable row level security',v_table);
    execute format('revoke all on table public.%I from public,anon,authenticated',v_table);
    execute format('grant all on table public.%I to service_role',v_table);
  end loop;
end $$;

revoke all on function public.openclaw_enqueue_projection(text,text,text,text,jsonb,timestamptz) from public,anon,authenticated;
revoke all on function public.bridge_pattern_skill_readiness() from public,anon,authenticated;
grant execute on function public.openclaw_enqueue_projection(text,text,text,text,jsonb,timestamptz) to service_role;
grant execute on function public.bridge_pattern_skill_readiness() to service_role;
grant execute on function public.bridge_pattern_skill_readiness() to authenticated;

insert into public.bridge_canonical_config(
  config_key,config_value,sensitivity,enabled,source,notes,created_at,updated_at
) values (
  'automation.evolution_system.v1',
  jsonb_build_object(
    'authority','supabase',
    'loop',jsonb_build_array(
      'observe','fingerprint','deduplicate','score','translate_to_english',
      'search_existing_solution','compose','sandbox','evaluate','canary',
      'activate','feedback','rollback_or_upgrade'
    ),
    'notion_role','projection_and_historical_evidence',
    'search_before_build',true,
    'high_risk_auto_promotion',false,
    'arbitrary_code_execution',false,
    'automatic_merge',false,
    'production_deploy',false,
    'secret_values_included',false
  ),
  'non_secret',true,'github-migration-openclaw-pattern-evolution-v1',
  'Version-controlled contract for the Supabase-authoritative pattern-to-skill evolution loop.',
  now(),now()
)
on conflict(config_key) do update set
  config_value=excluded.config_value,
  sensitivity='non_secret',enabled=true,source=excluded.source,notes=excluded.notes,updated_at=now();

commit;
