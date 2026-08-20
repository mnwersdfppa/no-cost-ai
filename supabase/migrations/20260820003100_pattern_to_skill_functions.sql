begin;

create or replace function public.bridge_refresh_pattern_candidate(p_fingerprint text)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_total bigint;
  v_source_count integer;
  v_title text;
  v_first timestamptz;
  v_last timestamptz;
  v_impact numeric;
  v_tokens numeric;
  v_automation numeric;
  v_reversibility numeric;
  v_confidence numeric;
  v_risk numeric;
  v_frequency numeric;
  v_recency numeric;
  v_reasoning numeric;
  v_priority numeric;
  v_evidence jsonb;
  v_row public.bridge_pattern_candidates;
begin
  if p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception 'valid_fingerprint_required';
  end if;

  select
    sum(occurrence_count)::bigint,
    count(*)::integer,
    (array_agg(canonical_title order by last_seen desc,updated_at desc))[1],
    min(first_seen),
    max(last_seen),
    sum(user_impact::numeric*occurrence_count)/nullif(sum(occurrence_count),0),
    sum(estimated_reasoning_tokens::numeric*occurrence_count)/nullif(sum(occurrence_count),0),
    sum(automation_fit::numeric*occurrence_count)/nullif(sum(occurrence_count),0),
    sum(reversibility::numeric*occurrence_count)/nullif(sum(occurrence_count),0),
    sum(confidence::numeric*occurrence_count)/nullif(sum(occurrence_count),0),
    sum(security_risk::numeric*occurrence_count)/nullif(sum(occurrence_count),0),
    jsonb_agg(jsonb_build_object(
      'source_type',source_type,
      'source_ref',source_ref,
      'occurrences',occurrence_count,
      'last_seen',last_seen,
      'pattern_kind',pattern_kind,
      'secret_values_included',false
    ) order by occurrence_count desc,last_seen desc)
  into
    v_total,v_source_count,v_title,v_first,v_last,v_impact,v_tokens,
    v_automation,v_reversibility,v_confidence,v_risk,v_evidence
  from public.bridge_pattern_observations
  where fingerprint=p_fingerprint;

  if coalesce(v_total,0)=0 then
    raise exception 'pattern_observation_not_found';
  end if;

  v_frequency := least(100,round((20*ln(v_total+1))::numeric,2));
  v_recency := case
    when v_last >= now()-interval '1 day' then 100
    when v_last >= now()-interval '7 days' then 85
    when v_last >= now()-interval '30 days' then 60
    when v_last >= now()-interval '90 days' then 35
    else 15
  end;
  v_reasoning := least(100,round((100*ln(coalesce(v_tokens,0)+1)/ln(10001))::numeric,2));
  v_impact := round(coalesce(v_impact,50),2);
  v_automation := round(coalesce(v_automation,50),2);
  v_reversibility := round(coalesce(v_reversibility,50),2);
  v_confidence := round(coalesce(v_confidence,50),2);
  v_risk := round(coalesce(v_risk,20),2);
  v_priority := greatest(0,least(100,round((
      0.24*v_frequency +
      0.08*v_recency +
      0.22*v_impact +
      0.16*v_reasoning +
      0.14*v_automation +
      0.06*v_reversibility +
      0.10*v_confidence -
      0.18*v_risk
    )::numeric,2)));

  insert into public.bridge_pattern_candidates(
    fingerprint,canonical_title,state,total_occurrences,source_count,
    first_seen,last_seen,frequency_score,recency_score,impact_score,
    reasoning_cost_score,automation_fit_score,reversibility_score,
    confidence_score,risk_score,priority_score,evidence_refs,
    scoring_version,scored_at,created_at,updated_at
  ) values (
    p_fingerprint,v_title,'translation_pending',v_total,v_source_count,
    v_first,v_last,v_frequency,v_recency,v_impact,v_reasoning,v_automation,
    v_reversibility,v_confidence,v_risk,v_priority,v_evidence,1,now(),now(),now()
  )
  on conflict(fingerprint) do update set
    canonical_title=excluded.canonical_title,
    total_occurrences=excluded.total_occurrences,
    source_count=excluded.source_count,
    first_seen=excluded.first_seen,
    last_seen=excluded.last_seen,
    frequency_score=excluded.frequency_score,
    recency_score=excluded.recency_score,
    impact_score=excluded.impact_score,
    reasoning_cost_score=excluded.reasoning_cost_score,
    automation_fit_score=excluded.automation_fit_score,
    reversibility_score=excluded.reversibility_score,
    confidence_score=excluded.confidence_score,
    risk_score=excluded.risk_score,
    priority_score=excluded.priority_score,
    evidence_refs=excluded.evidence_refs,
    state=case
      when bridge_pattern_candidates.state in ('skill_active','blocked','deferred') then bridge_pattern_candidates.state
      when bridge_pattern_candidates.english_query is null then 'translation_pending'
      when excluded.priority_score >= 45 and excluded.risk_score <= 70 then 'ready_for_research'
      else 'observed'
    end,
    translation_state=case
      when bridge_pattern_candidates.english_query is null then 'pending'
      else bridge_pattern_candidates.translation_state
    end,
    scoring_version=1,
    scored_at=now(),
    updated_at=now()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

create or replace function public.bridge_record_pattern_observation(
  p_source_type text,
  p_source_ref text,
  p_pattern_kind text,
  p_canonical_title text,
  p_redacted_summary text,
  p_error_code text default null,
  p_context jsonb default '{}'::jsonb,
  p_occurrence_count integer default 1,
  p_first_seen timestamptz default now(),
  p_last_seen timestamptz default now(),
  p_estimated_reasoning_tokens integer default 0,
  p_estimated_recovery_seconds integer default 0,
  p_user_impact smallint default 50,
  p_automation_fit smallint default 50,
  p_reversibility smallint default 50,
  p_confidence smallint default 50,
  p_security_risk smallint default 20,
  p_fingerprint text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_fingerprint text;
  v_summary text;
  v_title text;
begin
  v_title := trim(coalesce(p_canonical_title,''));
  v_summary := trim(coalesce(p_redacted_summary,''));
  if char_length(v_title) not between 3 and 240 then
    raise exception 'canonical_title_length_invalid';
  end if;
  if char_length(v_summary) not between 3 and 4000 then
    raise exception 'redacted_summary_length_invalid';
  end if;
  if v_summary ~* '(sk-proj-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|tskey-(auth|api|client)-[A-Za-z0-9_-]{12,}|Bearer[[:space:]]+[A-Za-z0-9._~+/-]{16,}|BEGIN[[:space:]]+(RSA|OPENSSH|EC)[[:space:]]+PRIVATE[[:space:]]+KEY)' then
    raise exception 'secret_like_summary_rejected';
  end if;
  if p_occurrence_count not between 1 and 1000000000 then
    raise exception 'occurrence_count_invalid';
  end if;
  if p_last_seen < p_first_seen then
    raise exception 'observation_time_range_invalid';
  end if;

  v_fingerprint := lower(coalesce(p_fingerprint,''));
  if v_fingerprint !~ '^[0-9a-f]{64}$' then
    v_fingerprint := encode(digest(
      lower(v_title)||'|'||lower(coalesce(p_error_code,''))||'|'||lower(coalesce(p_pattern_kind,'other')),
      'sha256'
    ),'hex');
  end if;

  insert into public.bridge_pattern_observations(
    fingerprint,source_type,source_ref,pattern_kind,canonical_title,
    redacted_summary,error_code,context,occurrence_count,first_seen,last_seen,
    estimated_reasoning_tokens,estimated_recovery_seconds,user_impact,
    automation_fit,reversibility,confidence,security_risk,
    redaction_applied,secret_values_included,created_at,updated_at
  ) values (
    v_fingerprint,p_source_type,nullif(trim(coalesce(p_source_ref,'')),''),
    p_pattern_kind,v_title,v_summary,nullif(trim(coalesce(p_error_code,'')),''),
    coalesce(p_context,'{}'::jsonb),p_occurrence_count,p_first_seen,p_last_seen,
    greatest(0,p_estimated_reasoning_tokens),greatest(0,p_estimated_recovery_seconds),
    greatest(0,least(100,p_user_impact)),greatest(0,least(100,p_automation_fit)),
    greatest(0,least(100,p_reversibility)),greatest(0,least(100,p_confidence)),
    greatest(0,least(100,p_security_risk)),true,false,now(),now()
  )
  on conflict(fingerprint,source_type,source_ref_key) do update set
    occurrence_count=least(1000000000,
      bridge_pattern_observations.occurrence_count+excluded.occurrence_count),
    first_seen=least(bridge_pattern_observations.first_seen,excluded.first_seen),
    last_seen=greatest(bridge_pattern_observations.last_seen,excluded.last_seen),
    redacted_summary=excluded.redacted_summary,
    context=bridge_pattern_observations.context||excluded.context,
    estimated_reasoning_tokens=greatest(
      bridge_pattern_observations.estimated_reasoning_tokens,
      excluded.estimated_reasoning_tokens
    ),
    estimated_recovery_seconds=greatest(
      bridge_pattern_observations.estimated_recovery_seconds,
      excluded.estimated_recovery_seconds
    ),
    user_impact=greatest(bridge_pattern_observations.user_impact,excluded.user_impact),
    automation_fit=greatest(bridge_pattern_observations.automation_fit,excluded.automation_fit),
    reversibility=greatest(bridge_pattern_observations.reversibility,excluded.reversibility),
    confidence=greatest(bridge_pattern_observations.confidence,excluded.confidence),
    security_risk=greatest(bridge_pattern_observations.security_risk,excluded.security_risk),
    redaction_applied=true,
    secret_values_included=false,
    updated_at=now();

  return public.bridge_refresh_pattern_candidate(v_fingerprint);
end;
$$;

create or replace function public.bridge_score_pattern_candidates()
returns integer
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_fingerprint text;
  v_count integer := 0;
begin
  for v_fingerprint in
    select distinct fingerprint from public.bridge_pattern_observations
  loop
    perform public.bridge_refresh_pattern_candidate(v_fingerprint);
    v_count := v_count+1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.bridge_enqueue_pattern_research(p_limit integer default 25)
returns integer
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_count integer;
begin
  with candidates as (
    select candidate_id,english_query,priority_score
    from public.bridge_pattern_candidates
    where state in ('ready_for_research','researching')
      and translation_state in ('ready','verified')
      and english_query is not null
      and char_length(english_query) between 8 and 1000
      and priority_score >= 45
      and risk_score <= 70
    order by priority_score desc,last_seen desc
    limit greatest(1,least(coalesce(p_limit,25),100))
  ), providers(provider) as (
    values ('official_docs'),('github'),('mcp_registry'),('n8n_templates'),('internal_catalog')
  ), inserted as (
    insert into public.bridge_research_queue(
      candidate_id,provider,english_query,query_hash,state,priority,
      attempts,max_attempts,not_before,secret_values_included,created_at,updated_at
    )
    select
      c.candidate_id,p.provider,c.english_query,
      encode(digest(lower(trim(c.english_query))||'|'||p.provider,'sha256'),'hex'),
      'queued',greatest(0,least(100,round(c.priority_score)::integer)),
      0,5,now(),false,now(),now()
    from candidates c cross join providers p
    on conflict(candidate_id,provider,query_hash) do nothing
    returning candidate_id
  )
  select count(*) into v_count from inserted;

  update public.bridge_pattern_candidates c
  set state='researching',updated_at=now()
  where exists (
    select 1 from public.bridge_research_queue q
    where q.candidate_id=c.candidate_id and q.state in ('queued','claimed')
  ) and c.state='ready_for_research';

  return coalesce(v_count,0);
end;
$$;

create or replace function public.bridge_claim_research_task(
  p_worker text,
  p_lease_minutes integer default 10
)
returns setof public.bridge_research_queue
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_id uuid;
begin
  if char_length(trim(coalesce(p_worker,''))) not between 3 and 120 then
    raise exception 'valid_worker_required';
  end if;
  select research_id into v_id
  from public.bridge_research_queue
  where state='queued'
    and not_before <= now()
    and attempts < max_attempts
  order by priority desc,created_at
  for update skip locked
  limit 1;

  if v_id is null then return; end if;

  return query
  update public.bridge_research_queue
  set state='claimed',
      attempts=attempts+1,
      lease_until=now()+make_interval(mins=>greatest(1,least(coalesce(p_lease_minutes,10),60))),
      claimed_by=left(trim(p_worker),120),
      updated_at=now()
  where research_id=v_id
  returning *;
end;
$$;

create or replace function public.bridge_skill_gate_status(p_skill_key text)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_skill public.bridge_skill_registry;
  v_gate text;
  v_missing text[] := array[]::text[];
  v_forbidden text[] := array[]::text[];
  v_permission text;
  v_failed_runs integer := 0;
  v_success_runs integer := 0;
  v_low_risk_category boolean;
  v_canary_allowed boolean;
  v_active_allowed boolean;
begin
  select * into v_skill from public.bridge_skill_registry where skill_key=p_skill_key;
  if not found then raise exception 'skill_not_found'; end if;

  foreach v_gate in array v_skill.required_gates loop
    if not exists (
      select 1
      from public.bridge_skill_evaluations e
      where e.skill_key=v_skill.skill_key
        and e.version=v_skill.current_version
        and e.evaluation_type=v_gate
        and e.passed=true
        and e.evaluated_at=(
          select max(e2.evaluated_at)
          from public.bridge_skill_evaluations e2
          where e2.skill_key=e.skill_key
            and e2.version=e.version
            and e2.evaluation_type=e.evaluation_type
        )
    ) then
      v_missing := array_append(v_missing,v_gate);
    end if;
  end loop;

  for v_permission in
    select lower(value)
    from jsonb_array_elements_text(
      case when jsonb_typeof(v_skill.permissions)='array' then v_skill.permissions else '[]'::jsonb end
    ) value
  loop
    if v_permission ~ '(root|sudo|shell|arbitrary_exec|credential_scope_change|secret_export|public_network|data_delete|billing|paid_api|telegram_poll|merge|prod_deploy|docker_socket|privileged)' then
      v_forbidden := array_append(v_forbidden,v_permission);
    end if;
  end loop;

  select
    count(*) filter (where state in ('failed','rolled_back')),
    count(*) filter (where state='succeeded')
  into v_failed_runs,v_success_runs
  from public.bridge_automation_runs
  where skill_key=v_skill.skill_key
    and skill_version=v_skill.current_version
    and started_at >= coalesce(v_skill.canary_started_at,now()-interval '30 days');

  v_low_risk_category := v_skill.category in (
    'validation','deduplication','retry','cache','classification','read_only_api',
    'schema_check','health_check','reporting','compatibility','migration'
  );
  v_canary_allowed :=
    v_skill.auto_promotable
    and v_skill.risk_tier='low'
    and v_low_risk_category
    and cardinality(v_missing)=0
    and cardinality(v_forbidden)=0
    and v_skill.current_version>0;
  v_active_allowed :=
    v_canary_allowed
    and v_skill.state='canary'
    and v_skill.canary_started_at is not null
    and v_skill.canary_started_at <= now()-interval '30 minutes'
    and v_success_runs>=3
    and v_failed_runs=0;

  return jsonb_build_object(
    'skill_key',v_skill.skill_key,
    'state',v_skill.state,
    'version',v_skill.current_version,
    'risk_tier',v_skill.risk_tier,
    'auto_promotable',v_skill.auto_promotable,
    'low_risk_category',v_low_risk_category,
    'missing_gates',to_jsonb(v_missing),
    'forbidden_permissions',to_jsonb(v_forbidden),
    'canary_success_runs',v_success_runs,
    'canary_failed_runs',v_failed_runs,
    'canary_allowed',v_canary_allowed,
    'active_allowed',v_active_allowed,
    'metadata_only_promotion',true,
    'arbitrary_code_execution',false,
    'secret_values_included',false
  );
end;
$$;

create or replace function public.bridge_promote_skill_candidate(
  p_skill_key text,
  p_target_state text,
  p_actor text default 'pattern-skill-sweeper'
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_gate jsonb;
  v_row public.bridge_skill_registry;
begin
  if p_target_state not in ('canary','active') then
    raise exception 'unsupported_promotion_target';
  end if;
  v_gate := public.bridge_skill_gate_status(p_skill_key);
  if p_target_state='canary' and coalesce((v_gate->>'canary_allowed')::boolean,false)=false then
    raise exception 'skill_canary_gate_failed:%',v_gate;
  end if;
  if p_target_state='active' and coalesce((v_gate->>'active_allowed')::boolean,false)=false then
    raise exception 'skill_active_gate_failed:%',v_gate;
  end if;

  update public.bridge_skill_registry
  set state=p_target_state,
      canary_started_at=case when p_target_state='canary' then now() else canary_started_at end,
      activated_at=case when p_target_state='active' then now() else activated_at end,
      updated_at=now()
  where skill_key=p_skill_key
  returning * into v_row;

  insert into public.bridge_events(
    event_type,node_name,correlation_id,severity,outcome,detail,created_at
  ) values (
    'pattern_skill_promoted','supabase',gen_random_uuid()::text,'info','succeeded',
    jsonb_build_object(
      'skill_key',p_skill_key,
      'target_state',p_target_state,
      'actor',left(coalesce(p_actor,'system'),120),
      'version',v_row.current_version,
      'metadata_only_promotion',true,
      'arbitrary_code_execution',false,
      'secret_values_included',false
    ),now()
  );

  return jsonb_build_object('ok',true,'skill',to_jsonb(v_row),'gate',v_gate,'secret_values_included',false);
end;
$$;

create or replace function public.bridge_pattern_skill_sweep()
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_bucket text := floor(extract(epoch from clock_timestamp())/1800)::bigint::text;
  v_execution_key text := 'pattern-skill-sweep:'||v_bucket;
  v_research_execution_key text := 'research-before-build:'||v_bucket;
  v_run_id uuid;
  v_research_run_id uuid;
  v_scored integer := 0;
  v_enqueued integer := 0;
  v_promoted_canary integer := 0;
  v_promoted_active integer := 0;
  v_skill record;
  v_error text;
begin
  insert into public.bridge_automation_runs(
    skill_key,skill_version,execution_key,trigger_type,state,
    result_summary,tokens_saved_estimate,reasoning_steps_avoided,
    rollback_performed,secret_values_included,started_at
  ) values(
    'pattern.to.skill.sweeper',1,v_execution_key,'cron_or_manual','running',
    jsonb_build_object('time_bucket',v_bucket,'secret_values_included',false),
    0,0,false,false,now()
  )
  on conflict(skill_key,execution_key) do nothing
  returning run_id into v_run_id;

  if v_run_id is null then
    return jsonb_build_object(
      'ok',true,
      'state','duplicate',
      'execution_key',v_execution_key,
      'patterns_scored',0,
      'research_tasks_enqueued',0,
      'skills_promoted_to_canary',0,
      'skills_promoted_to_active',0,
      'arbitrary_code_execution',false,
      'secret_values_included',false,
      'completed_at',now()
    );
  end if;

  insert into public.bridge_automation_runs(
    skill_key,skill_version,execution_key,trigger_type,state,
    result_summary,tokens_saved_estimate,reasoning_steps_avoided,
    rollback_performed,secret_values_included,started_at
  ) values(
    'research.search-before-build',1,v_research_execution_key,'pattern_sweep','running',
    jsonb_build_object('time_bucket',v_bucket,'secret_values_included',false),
    0,0,false,false,now()
  )
  on conflict(skill_key,execution_key) do nothing
  returning run_id into v_research_run_id;

  begin
    v_scored := public.bridge_score_pattern_candidates();
    v_enqueued := public.bridge_enqueue_pattern_research(50);

    update public.bridge_automation_runs
    set state='succeeded',
        result_summary=jsonb_build_object(
          'patterns_scored',v_scored,
          'research_tasks_enqueued',v_enqueued,
          'translation_is_cached',true,
          'search_before_build',true,
          'arbitrary_code_execution',false,
          'secret_values_included',false
        ),
        completed_at=now()
    where run_id=v_run_id;

    if v_research_run_id is not null then
      update public.bridge_automation_runs
      set state='succeeded',
          result_summary=jsonb_build_object(
            'research_tasks_enqueued',v_enqueued,
            'providers',jsonb_build_array(
              'official_docs','github','mcp_registry','n8n_templates','internal_catalog'
            ),
            'external_fetch_executed',false,
            'arbitrary_code_execution',false,
            'secret_values_included',false
          ),
          completed_at=now()
      where run_id=v_research_run_id;
    end if;

    for v_skill in
      select skill_key
      from public.bridge_skill_registry
      where state='validated'
        and auto_promotable=true
        and risk_tier='low'
      order by updated_at,skill_key
      limit 20
    loop
      begin
        perform public.bridge_promote_skill_candidate(
          v_skill.skill_key,'canary','pattern-skill-sweeper'
        );
        v_promoted_canary := v_promoted_canary+1;
      exception when others then
        null;
      end;
    end loop;

    for v_skill in
      select skill_key
      from public.bridge_skill_registry
      where state='canary'
        and auto_promotable=true
        and risk_tier='low'
      order by canary_started_at,skill_key
      limit 20
    loop
      begin
        perform public.bridge_promote_skill_candidate(
          v_skill.skill_key,'active','pattern-skill-sweeper'
        );
        v_promoted_active := v_promoted_active+1;
      exception when others then
        null;
      end;
    end loop;

    update public.bridge_automation_runs
    set result_summary=result_summary||jsonb_build_object(
          'skills_promoted_to_canary',v_promoted_canary,
          'skills_promoted_to_active',v_promoted_active,
          'metadata_only_promotion',true
        )
    where run_id=v_run_id;

    insert into public.bridge_events(
      event_type,node_name,correlation_id,severity,outcome,detail,created_at
    ) values(
      'pattern_skill_sweep_run','supabase',v_execution_key,'info','succeeded',
      jsonb_build_object(
        'patterns_scored',v_scored,
        'research_tasks_enqueued',v_enqueued,
        'skills_promoted_to_canary',v_promoted_canary,
        'skills_promoted_to_active',v_promoted_active,
        'metadata_only_promotion',true,
        'arbitrary_code_execution',false,
        'secret_values_included',false
      ),now()
    );

    return jsonb_build_object(
      'ok',true,
      'state','succeeded',
      'execution_key',v_execution_key,
      'patterns_scored',v_scored,
      'research_tasks_enqueued',v_enqueued,
      'skills_promoted_to_canary',v_promoted_canary,
      'skills_promoted_to_active',v_promoted_active,
      'metadata_only_promotion',true,
      'arbitrary_code_execution',false,
      'secret_values_included',false,
      'completed_at',now()
    );
  exception when others then
    v_error := left(regexp_replace(SQLERRM,'[^A-Za-z0-9_.:-]+','_','g'),240);
    update public.bridge_automation_runs
    set state='failed',
        error_code=v_error,
        result_summary=jsonb_build_object(
          'patterns_scored',v_scored,
          'research_tasks_enqueued',v_enqueued,
          'arbitrary_code_execution',false,
          'secret_values_included',false
        ),
        completed_at=now()
    where run_id in (v_run_id,v_research_run_id);

    insert into public.bridge_events(
      event_type,node_name,correlation_id,severity,outcome,detail,created_at
    ) values(
      'pattern_skill_sweep_run','supabase',v_execution_key,'warning','failed',
      jsonb_build_object(
        'error_code',v_error,
        'arbitrary_code_execution',false,
        'secret_values_included',false
      ),now()
    );

    return jsonb_build_object(
      'ok',false,
      'state','failed',
      'execution_key',v_execution_key,
      'error_code',v_error,
      'arbitrary_code_execution',false,
      'secret_values_included',false,
      'completed_at',now()
    );
  end;
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
      'sandboxed',(select count(*) from public.bridge_skill_registry where state='sandboxed'),
      'validated',(select count(*) from public.bridge_skill_registry where state='validated'),
      'canary',(select count(*) from public.bridge_skill_registry where state='canary'),
      'active',(select count(*) from public.bridge_skill_registry where state='active'),
      'blocked',(select count(*) from public.bridge_skill_registry where state='blocked')
    ),
    'top_patterns',coalesce((
      select jsonb_agg(jsonb_build_object(
        'fingerprint',fingerprint,
        'title',canonical_title,
        'state',state,
        'occurrences',total_occurrences,
        'priority',priority_score,
        'risk',risk_score,
        'translation_state',translation_state,
        'secret_values_included',false
      ) order by priority_score desc,last_seen desc)
      from (
        select * from public.bridge_pattern_candidates
        order by priority_score desc,last_seen desc
        limit 10
      ) ranked
    ),'[]'::jsonb),
    'active_skills',coalesce((
      select jsonb_agg(jsonb_build_object(
        'skill_key',skill_key,
        'name',display_name,
        'category',category,
        'version',current_version,
        'risk_tier',risk_tier,
        'activated_at',activated_at,
        'secret_values_included',false
      ) order by skill_key)
      from public.bridge_skill_registry
      where state='active'
    ),'[]'::jsonb),
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

DO $$
declare
  v_function text;
begin
  foreach v_function in array array[
    'bridge_refresh_pattern_candidate(text)',
    'bridge_record_pattern_observation(text,text,text,text,text,text,jsonb,integer,timestamptz,timestamptz,integer,integer,smallint,smallint,smallint,smallint,smallint,text)',
    'bridge_score_pattern_candidates()',
    'bridge_enqueue_pattern_research(integer)',
    'bridge_claim_research_task(text,integer)',
    'bridge_skill_gate_status(text)',
    'bridge_promote_skill_candidate(text,text,text)',
    'bridge_pattern_skill_sweep()',
    'bridge_pattern_skill_readiness()'
  ] loop
    execute format('revoke all on function public.%s from public,anon,authenticated',v_function);
    execute format('grant execute on function public.%s to service_role',v_function);
  end loop;
end $$;

grant execute on function public.bridge_pattern_skill_readiness() to authenticated;

commit;
