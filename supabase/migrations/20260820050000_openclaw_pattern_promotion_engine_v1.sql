begin;

create table if not exists public.openclaw_pattern_rules (
  rule_key text primary key,
  source_kind text not null check (source_kind in ('bridge_event','work_queue','request_ledger','command_decision','notion','manual')),
  match_regex text not null,
  pattern_key text not null,
  category text not null check (category in ('error','reasoning','operation','approval','compatibility','data_quality','credential','routing','observability')),
  priority integer not null default 100,
  default_tokens_saved integer not null default 0 check (default_tokens_saved >= 0),
  default_minutes_saved numeric(12,2) not null default 0 check (default_minutes_saved >= 0),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.openclaw_pattern_candidates (
  pattern_key text primary key,
  title_ko text not null,
  title_en text not null,
  category text not null check (category in ('error','reasoning','operation','approval','compatibility','data_quality','credential','routing','observability')),
  description text not null default '',
  automation_target text not null default 'deterministic_macro',
  status text not null default 'observe' check (status in ('observe','macro_candidate','skill_candidate','verified','active','quarantined','retired')),
  risk_level text not null default 'low' check (risk_level in ('low','medium','high','critical')),
  deterministic boolean not null default true,
  reversible boolean not null default true,
  requires_approval boolean not null default false,
  manual_status_lock boolean not null default false,
  frequency_30d integer not null default 0,
  frequency_90d integer not null default 0,
  success_count_90d integer not null default 0,
  failure_count_90d integer not null default 0,
  duplicate_count_90d integer not null default 0,
  estimated_tokens_saved_90d bigint not null default 0,
  estimated_minutes_saved_90d numeric(14,2) not null default 0,
  posterior_success numeric(8,5) not null default 0.5,
  frequency_score numeric(6,2) not null default 0,
  friction_score numeric(6,2) not null default 0,
  savings_score numeric(6,2) not null default 0,
  evidence_score numeric(6,2) not null default 0,
  risk_penalty numeric(6,2) not null default 0,
  promotion_score numeric(6,2) not null default 0,
  ci_state text not null default 'not_tested' check (ci_state in ('not_tested','pending','pass','fail')),
  e2e_state text not null default 'not_tested' check (e2e_state in ('not_tested','pending','pass','fail')),
  skill_name text,
  macro_spec jsonb not null default '{}'::jsonb,
  skill_spec jsonb not null default '{}'::jsonb,
  preconditions jsonb not null default '{}'::jsonb,
  rollback_spec jsonb not null default '{}'::jsonb,
  verification_spec jsonb not null default '{}'::jsonb,
  route_policy jsonb not null default '{}'::jsonb,
  current_version integer not null default 1 check (current_version > 0),
  last_observed_at timestamptz,
  last_promoted_at timestamptz,
  cooldown_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.openclaw_pattern_observations (
  observation_id bigserial primary key,
  pattern_key text not null references public.openclaw_pattern_candidates(pattern_key) on update cascade on delete restrict,
  category text not null check (category in ('error','reasoning','operation','approval','compatibility','data_quality','credential','routing','observability')),
  source_system text not null,
  source_ref text not null,
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
  severity text not null default 'info' check (severity in ('debug','info','warning','error','critical')),
  outcome text not null default 'observed',
  success boolean,
  duration_ms integer check (duration_ms is null or duration_ms >= 0),
  tokens_saved_estimate integer not null default 0 check (tokens_saved_estimate >= 0),
  minutes_saved_estimate numeric(12,2) not null default 0 check (minutes_saved_estimate >= 0),
  safe_context jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  ingested_at timestamptz not null default now(),
  unique(source_system,source_ref,fingerprint)
);

create table if not exists public.openclaw_pattern_feedback (
  feedback_id uuid primary key default gen_random_uuid(),
  pattern_key text not null references public.openclaw_pattern_candidates(pattern_key) on update cascade on delete restrict,
  skill_name text,
  skill_version integer,
  execution_key text not null,
  outcome text not null check (outcome in ('succeeded','failed','blocked','rolled_back','cancelled')),
  reward numeric(6,5) not null check (reward >= -1 and reward <= 1),
  latency_ms integer check (latency_ms is null or latency_ms >= 0),
  input_tokens integer check (input_tokens is null or input_tokens >= 0),
  output_tokens integer check (output_tokens is null or output_tokens >= 0),
  manual_intervention boolean not null default false,
  error_code text,
  safe_evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(pattern_key,execution_key)
);

create table if not exists public.openclaw_skill_versions (
  skill_name text not null,
  skill_version integer not null check (skill_version > 0),
  pattern_key text not null references public.openclaw_pattern_candidates(pattern_key) on update cascade on delete restrict,
  lifecycle_status text not null check (lifecycle_status in ('draft','candidate','verified','active','quarantined','retired')),
  specification jsonb not null,
  source_repository text,
  source_branch text,
  source_commit text,
  ci_state text not null default 'not_tested' check (ci_state in ('not_tested','pending','pass','fail')),
  e2e_state text not null default 'not_tested' check (e2e_state in ('not_tested','pending','pass','fail')),
  success_count integer not null default 0,
  failure_count integer not null default 0,
  cumulative_reward numeric(16,5) not null default 0,
  activated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(skill_name,skill_version)
);

create table if not exists public.openclaw_pattern_evidence_links (
  evidence_id bigserial primary key,
  pattern_key text not null references public.openclaw_pattern_candidates(pattern_key) on update cascade on delete restrict,
  source_system text not null,
  source_ref text not null,
  source_title text,
  evidence_note text not null default '',
  observed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(pattern_key,source_system,source_ref)
);

create table if not exists public.openclaw_pattern_promotion_log (
  promotion_id bigserial primary key,
  pattern_key text not null references public.openclaw_pattern_candidates(pattern_key) on update cascade on delete restrict,
  from_status text,
  to_status text not null,
  actor text not null,
  reason text not null,
  score_snapshot numeric(6,2),
  evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.openclaw_capability_registry (
  capability_key text primary key,
  intent_key text not null,
  capability_type text not null check (capability_type in ('native_api','mcp','connector','deterministic_macro','host_adapter','container','local_model','cloud_model','manual')),
  provider text not null,
  operation text not null,
  endpoint_ref text,
  deterministic boolean not null default false,
  cost_tier smallint not null default 0 check (cost_tier between 0 and 5),
  latency_tier smallint not null default 3 check (latency_tier between 1 and 5),
  permission_risk smallint not null default 0 check (permission_risk between 0 and 5),
  reliability_score numeric(6,5) not null default 0.5 check (reliability_score between 0 and 1),
  requires_network boolean not null default true,
  status text not null default 'active' check (status in ('active','degraded','disabled','pending_verification')),
  priority integer not null default 100,
  metadata jsonb not null default '{}'::jsonb,
  last_verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists openclaw_pattern_rules_lookup_idx on public.openclaw_pattern_rules(source_kind,enabled,priority desc);
create index if not exists openclaw_pattern_observations_pattern_time_idx on public.openclaw_pattern_observations(pattern_key,occurred_at desc);
create index if not exists openclaw_pattern_observations_source_idx on public.openclaw_pattern_observations(source_system,source_ref);
create index if not exists openclaw_pattern_feedback_pattern_time_idx on public.openclaw_pattern_feedback(pattern_key,created_at desc);
create index if not exists openclaw_pattern_candidates_score_idx on public.openclaw_pattern_candidates(status,promotion_score desc,updated_at desc);
create index if not exists openclaw_capability_registry_intent_idx on public.openclaw_capability_registry(intent_key,status,priority,reliability_score desc);

alter table public.openclaw_pattern_rules enable row level security;
alter table public.openclaw_pattern_candidates enable row level security;
alter table public.openclaw_pattern_observations enable row level security;
alter table public.openclaw_pattern_feedback enable row level security;
alter table public.openclaw_skill_versions enable row level security;
alter table public.openclaw_pattern_evidence_links enable row level security;
alter table public.openclaw_pattern_promotion_log enable row level security;
alter table public.openclaw_capability_registry enable row level security;

revoke all on public.openclaw_pattern_rules from anon,authenticated;
revoke all on public.openclaw_pattern_candidates from anon,authenticated;
revoke all on public.openclaw_pattern_observations from anon,authenticated;
revoke all on public.openclaw_pattern_feedback from anon,authenticated;
revoke all on public.openclaw_skill_versions from anon,authenticated;
revoke all on public.openclaw_pattern_evidence_links from anon,authenticated;
revoke all on public.openclaw_pattern_promotion_log from anon,authenticated;
revoke all on public.openclaw_capability_registry from anon,authenticated;

grant all on public.openclaw_pattern_rules to service_role;
grant all on public.openclaw_pattern_candidates to service_role;
grant all on public.openclaw_pattern_observations to service_role;
grant all on public.openclaw_pattern_feedback to service_role;
grant all on public.openclaw_skill_versions to service_role;
grant all on public.openclaw_pattern_evidence_links to service_role;
grant all on public.openclaw_pattern_promotion_log to service_role;
grant all on public.openclaw_capability_registry to service_role;
grant usage,select on sequence public.openclaw_pattern_observations_observation_id_seq to service_role;
grant usage,select on sequence public.openclaw_pattern_evidence_links_evidence_id_seq to service_role;
grant usage,select on sequence public.openclaw_pattern_promotion_log_promotion_id_seq to service_role;

create or replace function public.openclaw_safe_code(p_value text,p_limit integer default 120)
returns text language sql immutable
as $$
  select left(regexp_replace(coalesce(p_value,''),'[^A-Za-z0-9_.:-]+','_','g'),greatest(1,least(coalesce(p_limit,120),500)));
$$;

create or replace function public.openclaw_pattern_fingerprint(
  p_pattern_key text,p_source_system text,p_source_ref text,p_outcome text default ''
)
returns text language sql immutable
as $$
  select encode(digest(concat_ws('|',lower(trim(p_pattern_key)),lower(trim(p_source_system)),trim(p_source_ref),lower(trim(coalesce(p_outcome,'')))),'sha256'),'hex');
$$;

create or replace function public.openclaw_register_pattern_observation(
  p_pattern_key text,p_category text,p_source_system text,p_source_ref text,
  p_severity text default 'info',p_outcome text default 'observed',p_success boolean default null,
  p_duration_ms integer default null,p_tokens_saved_estimate integer default 0,
  p_minutes_saved_estimate numeric default 0,p_safe_context jsonb default '{}'::jsonb,
  p_occurred_at timestamptz default now()
)
returns bigint language plpgsql security definer
set search_path=public,extensions,pg_temp
as $$
declare v_fingerprint text; v_id bigint; v_context_text text;
begin
  if p_pattern_key is null or p_pattern_key !~ '^[a-z0-9][a-z0-9_.-]{2,119}$' then raise exception 'invalid_pattern_key'; end if;
  if p_category not in ('error','reasoning','operation','approval','compatibility','data_quality','credential','routing','observability') then raise exception 'invalid_pattern_category'; end if;
  if p_source_system is null or length(trim(p_source_system))<2 or length(p_source_system)>100 then raise exception 'invalid_source_system'; end if;
  if p_source_ref is null or length(trim(p_source_ref))<1 or length(p_source_ref)>240 then raise exception 'invalid_source_ref'; end if;
  v_context_text:=coalesce(p_safe_context,'{}'::jsonb)::text;
  if octet_length(v_context_text)>16384 then raise exception 'safe_context_too_large'; end if;
  if v_context_text ~* '(sk-proj-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{16,}|tskey-(auth|api|client)-[A-Za-z0-9_-]{12,}|Bearer[[:space:]]+[A-Za-z0-9._~+/-]{16,}|BEGIN[[:space:]]+(RSA|OPENSSH|EC)[[:space:]]+PRIVATE[[:space:]]+KEY)' then raise exception 'secret_like_context_rejected'; end if;

  insert into public.openclaw_pattern_candidates(pattern_key,title_ko,title_en,category,description)
  values(p_pattern_key,replace(p_pattern_key,'-',' '),replace(p_pattern_key,'-',' '),p_category,'Automatically discovered operational pattern.')
  on conflict(pattern_key) do nothing;

  v_fingerprint:=public.openclaw_pattern_fingerprint(p_pattern_key,p_source_system,p_source_ref,p_outcome);
  insert into public.openclaw_pattern_observations(
    pattern_key,category,source_system,source_ref,fingerprint,severity,outcome,success,
    duration_ms,tokens_saved_estimate,minutes_saved_estimate,safe_context,occurred_at
  ) values (
    p_pattern_key,p_category,trim(p_source_system),trim(p_source_ref),v_fingerprint,
    case when p_severity in ('debug','info','warning','error','critical') then p_severity else 'info' end,
    public.openclaw_safe_code(p_outcome,120),p_success,p_duration_ms,
    greatest(coalesce(p_tokens_saved_estimate,0),0),greatest(coalesce(p_minutes_saved_estimate,0),0),
    coalesce(p_safe_context,'{}'::jsonb),coalesce(p_occurred_at,now())
  ) on conflict(source_system,source_ref,fingerprint) do nothing returning observation_id into v_id;

  if v_id is null then
    select observation_id into v_id from public.openclaw_pattern_observations
    where source_system=trim(p_source_system) and source_ref=trim(p_source_ref) and fingerprint=v_fingerprint;
  end if;
  update public.openclaw_pattern_candidates
  set last_observed_at=greatest(coalesce(last_observed_at,'epoch'::timestamptz),coalesce(p_occurred_at,now())),updated_at=now()
  where pattern_key=p_pattern_key;
  return v_id;
end;
$$;

create or replace function public.openclaw_refresh_pattern_scores()
returns integer language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_rows integer;
begin
  with observation_rollup as (
    select pattern_key,
      count(*) filter(where occurred_at>=now()-interval '30 days')::integer frequency_30d,
      count(*)::integer frequency_90d,
      count(*) filter(where success is true)::integer success_count,
      count(*) filter(where success is false)::integer failure_count,
      count(*) filter(where outcome in ('duplicate','deduplicated','duplicate_execution_key'))::integer duplicate_count,
      coalesce(sum(tokens_saved_estimate),0)::bigint tokens_saved,
      coalesce(sum(minutes_saved_estimate),0)::numeric minutes_saved,
      max(occurred_at) last_observed_at
    from public.openclaw_pattern_observations
    where occurred_at>=now()-interval '90 days'
    group by pattern_key
  ), feedback_rollup as (
    select pattern_key,
      count(*) filter(where outcome='succeeded')::integer success_count,
      count(*) filter(where outcome in ('failed','blocked','rolled_back','cancelled'))::integer failure_count
    from public.openclaw_pattern_feedback
    where created_at>=now()-interval '90 days'
    group by pattern_key
  ), base as (
    select c.pattern_key,
      coalesce(o.frequency_30d,0) frequency_30d,coalesce(o.frequency_90d,0) frequency_90d,
      coalesce(o.success_count,0)+coalesce(f.success_count,0) success_count,
      coalesce(o.failure_count,0)+coalesce(f.failure_count,0) failure_count,
      coalesce(o.duplicate_count,0) duplicate_count,coalesce(o.tokens_saved,0) tokens_saved,
      coalesce(o.minutes_saved,0) minutes_saved,o.last_observed_at,
      least(30::numeric,round((10*ln(1+coalesce(o.frequency_90d,0)))::numeric,2)) frequency_score,
      least(20::numeric,(coalesce(o.failure_count,0)*4+coalesce(o.duplicate_count,0)*2)::numeric) friction_score,
      least(20::numeric,round((coalesce(o.minutes_saved,0)/5+coalesce(o.tokens_saved,0)/2000.0)::numeric,2)) savings_score,
      case when coalesce(o.frequency_90d,0)>=10 then 10::numeric when coalesce(o.frequency_90d,0)>=5 then 7::numeric when coalesce(o.frequency_90d,0)>=3 then 4::numeric when coalesce(o.frequency_90d,0)>0 then 1::numeric else 0::numeric end evidence_score,
      case c.risk_level when 'low' then 0::numeric when 'medium' then 10::numeric when 'high' then 25::numeric else 50::numeric end risk_penalty
    from public.openclaw_pattern_candidates c
    left join observation_rollup o using(pattern_key)
    left join feedback_rollup f using(pattern_key)
  ), scored as (
    select b.*,
      greatest(0::numeric,least(100::numeric,b.frequency_score+b.friction_score+b.savings_score+b.evidence_score+
        case when c.deterministic then 10 else 0 end+case when c.reversible then 10 else 0 end-b.risk_penalty)) promotion_score,
      ((b.success_count+1)::numeric/(b.success_count+b.failure_count+2)::numeric) posterior_success
    from base b join public.openclaw_pattern_candidates c using(pattern_key)
  )
  update public.openclaw_pattern_candidates c set
    frequency_30d=s.frequency_30d,frequency_90d=s.frequency_90d,
    success_count_90d=s.success_count,failure_count_90d=s.failure_count,duplicate_count_90d=s.duplicate_count,
    estimated_tokens_saved_90d=s.tokens_saved,estimated_minutes_saved_90d=s.minutes_saved,
    posterior_success=round(s.posterior_success,5),frequency_score=s.frequency_score,friction_score=s.friction_score,
    savings_score=s.savings_score,evidence_score=s.evidence_score,risk_penalty=s.risk_penalty,promotion_score=s.promotion_score,
    last_observed_at=coalesce(s.last_observed_at,c.last_observed_at),
    status=case
      when c.manual_status_lock or c.status in ('active','quarantined','retired') then c.status
      when s.promotion_score>=80 and c.risk_level='low' and c.ci_state='pass' and c.e2e_state='pass' and c.rollback_spec<>'{}'::jsonb then 'verified'
      when s.promotion_score>=65 then 'skill_candidate'
      when s.promotion_score>=45 then 'macro_candidate'
      else 'observe' end,
    updated_at=now()
  from scored s where c.pattern_key=s.pattern_key;
  get diagnostics v_rows=row_count;
  return v_rows;
end;
$$;

create or replace function public.openclaw_record_pattern_feedback(
  p_pattern_key text,p_execution_key text,p_outcome text,p_reward numeric,
  p_skill_name text default null,p_skill_version integer default null,p_latency_ms integer default null,
  p_input_tokens integer default null,p_output_tokens integer default null,p_manual_intervention boolean default false,
  p_error_code text default null,p_safe_evidence jsonb default '{}'::jsonb
)
returns uuid language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_id uuid; v_text text;
begin
  if p_outcome not in ('succeeded','failed','blocked','rolled_back','cancelled') then raise exception 'invalid_feedback_outcome'; end if;
  if p_reward<-1 or p_reward>1 then raise exception 'invalid_reward'; end if;
  if p_execution_key is null or length(trim(p_execution_key))<3 or length(p_execution_key)>160 then raise exception 'invalid_execution_key'; end if;
  v_text:=coalesce(p_safe_evidence,'{}'::jsonb)::text;
  if octet_length(v_text)>16384 then raise exception 'safe_evidence_too_large'; end if;
  if v_text ~* '(sk-proj-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{16,}|tskey-(auth|api|client)-[A-Za-z0-9_-]{12,}|Bearer[[:space:]]+[A-Za-z0-9._~+/-]{16,})' then raise exception 'secret_like_evidence_rejected'; end if;
  insert into public.openclaw_pattern_feedback(
    pattern_key,skill_name,skill_version,execution_key,outcome,reward,latency_ms,input_tokens,output_tokens,manual_intervention,error_code,safe_evidence
  ) values (
    p_pattern_key,p_skill_name,p_skill_version,trim(p_execution_key),p_outcome,p_reward,p_latency_ms,p_input_tokens,p_output_tokens,
    coalesce(p_manual_intervention,false),public.openclaw_safe_code(p_error_code,120),coalesce(p_safe_evidence,'{}'::jsonb)
  ) on conflict(pattern_key,execution_key) do update set
    outcome=excluded.outcome,reward=excluded.reward,latency_ms=excluded.latency_ms,input_tokens=excluded.input_tokens,
    output_tokens=excluded.output_tokens,manual_intervention=excluded.manual_intervention,error_code=excluded.error_code,
    safe_evidence=excluded.safe_evidence,created_at=now()
  returning feedback_id into v_id;
  perform public.openclaw_refresh_pattern_scores();
  return v_id;
end;
$$;

create or replace function public.openclaw_resolve_capability(p_intent_key text,p_context jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer stable
set search_path=public,pg_temp
as $$
declare v_row public.openclaw_capability_registry;
begin
  select * into v_row from public.openclaw_capability_registry
  where intent_key=p_intent_key and status in ('active','degraded')
  order by case status when 'active' then 0 else 1 end,case when deterministic then 0 else 1 end,
    permission_risk,cost_tier,priority,reliability_score desc,latency_tier limit 1;
  if not found then
    return jsonb_build_object('ok',false,'intent_key',p_intent_key,'selected_capability',null,'reason','no_verified_capability','manual_review_required',true,'secret_values_included',false);
  end if;
  return jsonb_build_object(
    'ok',true,'intent_key',p_intent_key,'selected_capability',v_row.capability_key,
    'capability_type',v_row.capability_type,'provider',v_row.provider,'operation',v_row.operation,
    'endpoint_ref',v_row.endpoint_ref,'deterministic',v_row.deterministic,'cost_tier',v_row.cost_tier,
    'permission_risk',v_row.permission_risk,'reliability_score',v_row.reliability_score,
    'requires_network',v_row.requires_network,'metadata',v_row.metadata,
    'context_acknowledged',coalesce(p_context,'{}'::jsonb)<>'{}'::jsonb,'secret_values_included',false
  );
end;
$$;

create or replace function public.openclaw_promote_pattern(
  p_pattern_key text,p_target_status text,p_actor text,p_reason text,p_evidence jsonb default '{}'::jsonb
)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_candidate public.openclaw_pattern_candidates; v_from text; v_version integer;
begin
  if p_target_status not in ('macro_candidate','skill_candidate','verified','active','quarantined','retired') then raise exception 'invalid_target_status'; end if;
  select * into v_candidate from public.openclaw_pattern_candidates where pattern_key=p_pattern_key for update;
  if not found then raise exception 'pattern_not_found'; end if;
  if p_target_status='active' and (
    v_candidate.promotion_score<85 or v_candidate.risk_level<>'low' or v_candidate.ci_state<>'pass' or
    v_candidate.e2e_state<>'pass' or v_candidate.rollback_spec='{}'::jsonb or
    v_candidate.verification_spec='{}'::jsonb or v_candidate.skill_name is null
  ) then raise exception 'active_promotion_requirements_not_met'; end if;
  if p_target_status='verified' and (v_candidate.promotion_score<75 or v_candidate.ci_state<>'pass' or v_candidate.e2e_state<>'pass') then raise exception 'verified_promotion_requirements_not_met'; end if;
  if v_candidate.risk_level in ('high','critical') and p_target_status in ('verified','active') then raise exception 'high_risk_automatic_promotion_forbidden'; end if;
  v_from:=v_candidate.status;
  update public.openclaw_pattern_candidates set status=p_target_status,manual_status_lock=true,last_promoted_at=now(),updated_at=now() where pattern_key=p_pattern_key;
  insert into public.openclaw_pattern_promotion_log(pattern_key,from_status,to_status,actor,reason,score_snapshot,evidence)
  values(p_pattern_key,v_from,p_target_status,left(coalesce(p_actor,'unknown'),120),left(coalesce(p_reason,''),1000),v_candidate.promotion_score,coalesce(p_evidence,'{}'::jsonb));
  if p_target_status in ('verified','active') and v_candidate.skill_name is not null then
    v_version:=v_candidate.current_version;
    insert into public.openclaw_skill_versions(skill_name,skill_version,pattern_key,lifecycle_status,specification,ci_state,e2e_state,activated_at)
    values(v_candidate.skill_name,v_version,p_pattern_key,p_target_status,v_candidate.skill_spec,v_candidate.ci_state,v_candidate.e2e_state,case when p_target_status='active' then now() else null end)
    on conflict(skill_name,skill_version) do update set lifecycle_status=excluded.lifecycle_status,specification=excluded.specification,
      ci_state=excluded.ci_state,e2e_state=excluded.e2e_state,activated_at=excluded.activated_at,updated_at=now();
  end if;
  return jsonb_build_object('ok',true,'pattern_key',p_pattern_key,'from_status',v_from,'to_status',p_target_status,'promotion_score',v_candidate.promotion_score,'secret_values_included',false);
end;
$$;

create or replace function public.openclaw_harvest_operational_patterns()
returns integer language plpgsql security definer
set search_path=public,extensions,pg_temp
as $$
declare v_total integer:=0; v_count integer:=0;
begin
  with matched as (
    select e.event_id,e.event_type,e.severity,e.outcome,e.created_at,r.pattern_key,r.category,r.default_tokens_saved,r.default_minutes_saved
    from public.bridge_events e cross join lateral (
      select * from public.openclaw_pattern_rules r where r.enabled and r.source_kind='bridge_event'
      and concat_ws(':',e.event_type,e.outcome,e.severity) ~* r.match_regex order by r.priority desc limit 1
    ) r where e.created_at>=now()-interval '90 days'
  ), inserted as (
    insert into public.openclaw_pattern_observations(pattern_key,category,source_system,source_ref,fingerprint,severity,outcome,success,tokens_saved_estimate,minutes_saved_estimate,safe_context,occurred_at)
    select pattern_key,category,'bridge_events','bridge_event:'||event_id,
      public.openclaw_pattern_fingerprint(pattern_key,'bridge_events','bridge_event:'||event_id,outcome),
      case when severity in ('debug','info','warning','error','critical') then severity else 'info' end,
      public.openclaw_safe_code(outcome,120),case when outcome in ('succeeded','pass','observed','completed') then true when outcome in ('failed','blocked','error','cancelled') then false else null end,
      default_tokens_saved,default_minutes_saved,jsonb_build_object('event_type',event_type,'outcome',outcome,'severity',severity,'secret_values_included',false),created_at
    from matched on conflict(source_system,source_ref,fingerprint) do nothing returning 1
  ) select count(*) into v_count from inserted;
  v_total:=v_total+v_count;

  with matched as (
    select q.id,q.task_type,q.status,q.attempts,q.last_error,q.created_at,q.updated_at,r.pattern_key,r.category,r.default_tokens_saved,r.default_minutes_saved
    from public.openclaw_work_queue q cross join lateral (
      select * from public.openclaw_pattern_rules r where r.enabled and r.source_kind='work_queue'
      and concat_ws(':',q.task_type,q.status,coalesce(q.last_error,'')) ~* r.match_regex order by r.priority desc limit 1
    ) r where q.created_at>=now()-interval '90 days'
  ), inserted as (
    insert into public.openclaw_pattern_observations(pattern_key,category,source_system,source_ref,fingerprint,severity,outcome,success,tokens_saved_estimate,minutes_saved_estimate,safe_context,occurred_at)
    select pattern_key,category,'openclaw_work_queue','work_queue:'||id,
      public.openclaw_pattern_fingerprint(pattern_key,'openclaw_work_queue','work_queue:'||id,status),
      case when status in ('failed','cancelled') then 'warning' else 'info' end,status,
      case when status='completed' then true when status in ('failed','cancelled') then false else null end,
      default_tokens_saved,default_minutes_saved,jsonb_build_object('task_type',task_type,'status',status,'attempts',attempts,'error_code',public.openclaw_safe_code(last_error,120),'secret_values_included',false),coalesce(updated_at,created_at)
    from matched on conflict(source_system,source_ref,fingerprint) do nothing returning 1
  ) select count(*) into v_count from inserted;
  v_total:=v_total+v_count;

  with matched as (
    select l.request_id,l.action,l.allowed,l.duplicate,l.reason,l.created_at,r.pattern_key,r.category,r.default_tokens_saved,r.default_minutes_saved
    from public.bridge_request_ledger l cross join lateral (
      select * from public.openclaw_pattern_rules r where r.enabled and r.source_kind='request_ledger'
      and concat_ws(':',l.action,l.allowed,l.duplicate,coalesce(l.reason,'')) ~* r.match_regex order by r.priority desc limit 1
    ) r where l.created_at>=now()-interval '90 days'
  ), inserted as (
    insert into public.openclaw_pattern_observations(pattern_key,category,source_system,source_ref,fingerprint,severity,outcome,success,tokens_saved_estimate,minutes_saved_estimate,safe_context,occurred_at)
    select pattern_key,category,'bridge_request_ledger','request:'||request_id,
      public.openclaw_pattern_fingerprint(pattern_key,'bridge_request_ledger','request:'||request_id,coalesce(reason,'')),
      case when allowed then 'info' else 'warning' end,
      case when duplicate then 'duplicate_execution_key' when allowed then 'admitted' else public.openclaw_safe_code(reason,120) end,
      allowed,default_tokens_saved,default_minutes_saved,jsonb_build_object('action',action,'allowed',allowed,'duplicate',duplicate,'reason',public.openclaw_safe_code(reason,120),'secret_values_included',false),created_at
    from matched on conflict(source_system,source_ref,fingerprint) do nothing returning 1
  ) select count(*) into v_count from inserted;
  v_total:=v_total+v_count;

  with matched as (
    select d.decision_id,d.selected_action,d.selected_route,d.decision_policy,d.approval_state,d.confidence,d.created_at,r.pattern_key,r.category,r.default_tokens_saved,r.default_minutes_saved
    from public.command_decisions d cross join lateral (
      select * from public.openclaw_pattern_rules r where r.enabled and r.source_kind='command_decision'
      and concat_ws(':',d.selected_action,d.selected_route,d.decision_policy,d.approval_state) ~* r.match_regex order by r.priority desc limit 1
    ) r where d.created_at>=now()-interval '90 days'
  ), inserted as (
    insert into public.openclaw_pattern_observations(pattern_key,category,source_system,source_ref,fingerprint,severity,outcome,success,tokens_saved_estimate,minutes_saved_estimate,safe_context,occurred_at)
    select pattern_key,category,'command_decisions','decision:'||decision_id,
      public.openclaw_pattern_fingerprint(pattern_key,'command_decisions','decision:'||decision_id,approval_state),
      'info',approval_state,case when approval_state='approved' then true when approval_state in ('rejected','blocked') then false else null end,
      default_tokens_saved,default_minutes_saved,jsonb_build_object('selected_action',selected_action,'selected_route',selected_route,'decision_policy',decision_policy,'confidence',confidence,'secret_values_included',false),created_at
    from matched on conflict(source_system,source_ref,fingerprint) do nothing returning 1
  ) select count(*) into v_count from inserted;
  v_total:=v_total+v_count;
  perform public.openclaw_refresh_pattern_scores();
  return v_total;
end;
$$;

create or replace view public.openclaw_pattern_promotion_queue as
select pattern_key,title_ko,title_en,category,status,risk_level,deterministic,reversible,requires_approval,
  frequency_30d,frequency_90d,success_count_90d,failure_count_90d,duplicate_count_90d,
  posterior_success,promotion_score,ci_state,e2e_state,skill_name,last_observed_at,updated_at,
  case
    when status='observe' and promotion_score>=45 then 'prepare_macro_spec'
    when status='macro_candidate' and promotion_score>=65 then 'prepare_skill_and_ci'
    when status='skill_candidate' and ci_state='pass' and e2e_state='pass' and promotion_score>=75 then 'review_verified_promotion'
    when status='verified' and risk_level='low' and promotion_score>=85 then 'review_active_promotion'
    else 'collect_more_evidence' end next_action
from public.openclaw_pattern_candidates
where status not in ('retired','quarantined')
order by promotion_score desc,frequency_30d desc,updated_at desc;

create or replace view public.openclaw_capability_best_route as
select distinct on(intent_key) intent_key,capability_key,capability_type,provider,operation,endpoint_ref,deterministic,
  cost_tier,latency_tier,permission_risk,reliability_score,requires_network,status,priority,metadata,last_verified_at
from public.openclaw_capability_registry
where status in ('active','degraded')
order by intent_key,case status when 'active' then 0 else 1 end,case when deterministic then 0 else 1 end,
  permission_risk,cost_tier,priority,reliability_score desc,latency_tier;

revoke all on public.openclaw_pattern_promotion_queue from anon,authenticated;
revoke all on public.openclaw_capability_best_route from anon,authenticated;
grant select on public.openclaw_pattern_promotion_queue to service_role;
grant select on public.openclaw_capability_best_route to service_role;

revoke all on function public.openclaw_register_pattern_observation(text,text,text,text,text,text,boolean,integer,integer,numeric,jsonb,timestamptz) from public,anon,authenticated;
revoke all on function public.openclaw_refresh_pattern_scores() from public,anon,authenticated;
revoke all on function public.openclaw_record_pattern_feedback(text,text,text,numeric,text,integer,integer,integer,integer,boolean,text,jsonb) from public,anon,authenticated;
revoke all on function public.openclaw_resolve_capability(text,jsonb) from public,anon,authenticated;
revoke all on function public.openclaw_promote_pattern(text,text,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.openclaw_harvest_operational_patterns() from public,anon,authenticated;
grant execute on function public.openclaw_register_pattern_observation(text,text,text,text,text,text,boolean,integer,integer,numeric,jsonb,timestamptz) to service_role;
grant execute on function public.openclaw_refresh_pattern_scores() to service_role;
grant execute on function public.openclaw_record_pattern_feedback(text,text,text,numeric,text,integer,integer,integer,integer,boolean,text,jsonb) to service_role;
grant execute on function public.openclaw_resolve_capability(text,jsonb) to service_role;
grant execute on function public.openclaw_promote_pattern(text,text,text,text,jsonb) to service_role;
grant execute on function public.openclaw_harvest_operational_patterns() to service_role;

commit;
