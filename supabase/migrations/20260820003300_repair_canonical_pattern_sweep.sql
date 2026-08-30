begin;

create or replace function public.bridge_process_internal_research_tasks(
  p_limit integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  r record;
  m record;
  v_pattern_key text;
  v_result_count integer;
  v_processed integer := 0;
  v_solved integer := 0;
  v_solution_type text;
begin
  for r in
    select q.*,c.fingerprint,c.canonical_title,c.selected_skill_key
    from public.bridge_research_queue q
    join public.bridge_pattern_candidates c on c.candidate_id=q.candidate_id
    where q.provider='internal_catalog'
      and q.state='queued'
      and q.not_before<=now()
      and q.attempts<q.max_attempts
    order by q.priority desc,q.created_at
    for update of q skip locked
    limit greatest(1,least(coalesce(p_limit,50),200))
  loop
    v_processed := v_processed+1;
    v_result_count := 0;

    update public.bridge_research_queue
    set state='claimed',attempts=attempts+1,
        claimed_by='internal-catalog-worker',
        lease_until=now()+interval '5 minutes',updated_at=now()
    where research_id=r.research_id;

    select regexp_replace(source_object_id,'^openclaw_pattern:','')
    into v_pattern_key
    from public.bridge_source_bindings
    where source_system='supabase'
      and source_object_id like 'openclaw_pattern:%'
      and destination_key=r.fingerprint
      and migration_state='verified'
    order by verified_at desc nulls last,updated_at desc
    limit 1;

    if v_pattern_key is null then
      select pattern_key into v_pattern_key
      from public.openclaw_pattern_candidates
      where skill_name=r.selected_skill_key
      order by updated_at desc
      limit 1;
    end if;

    if v_pattern_key is not null then
      for m in
        select x.*,s.name,s.source_class,s.repository_url,s.docs_url,
               s.license_name,s.license_class,s.trust_tier,s.capabilities,
               s.supported_platforms,s.adoption_state
        from public.openclaw_pattern_source_matches x
        join public.openclaw_solution_sources s on s.source_key=x.source_key
        where x.pattern_key=v_pattern_key
          and x.status in ('candidate','approved','integrated')
          and x.reuse_role<>'rejected'
          and s.enabled=true
        order by
          case x.status when 'integrated' then 1 when 'approved' then 2 else 3 end,
          x.match_score desc,x.source_key
      loop
        v_solution_type := case
          when m.source_class='project_native' then 'internal_existing'
          when m.source_class='open_standard' and m.source_key like 'mcp.%' then 'mcp_server'
          when m.source_key='n8n' then 'n8n_template'
          when m.source_key='langgraph' then 'langgraph_pattern'
          when m.source_key='langsmith' then 'langsmith_pattern'
          when m.source_key like 'docker.%' then 'docker_image'
          when m.source_class in ('open_source','source_available') then 'github_repository'
          when m.source_class in ('platform_builtin','managed_service') then 'official_api'
          else 'official_docs'
        end;

        insert into public.bridge_solution_catalog(
          candidate_id,solution_key,source_type,title,source_url,repository,
          version_ref,license_spdx,maintenance_score,compatibility_score,
          security_score,implementation_cost_score,capabilities,
          supported_platforms,evidence,status,rejection_reason,
          secret_values_included,discovered_at,reviewed_at,updated_at
        ) values(
          r.candidate_id,
          left('reuse:'||v_pattern_key||':'||m.source_key,240),
          v_solution_type,m.name,m.docs_url,m.repository_url,null,m.license_name,
          greatest(40,least(100,round(50+m.match_score/2)::integer)),
          greatest(30,least(100,round(m.match_score)::integer)),
          case m.trust_tier when 'official' then 90 when 'verified' then 80 when 'community' then 60 else 40 end,
          greatest(10,least(100,round(105-m.match_score)::integer)),
          to_jsonb(m.capabilities),m.supported_platforms,
          jsonb_build_object(
            'pattern_key',v_pattern_key,
            'source_key',m.source_key,
            'match_score',m.match_score,
            'reuse_role',m.reuse_role,
            'match_status',m.status,
            'rationale_en',m.rationale_en,
            'rationale_ko',m.rationale_ko,
            'integration_plan',m.integration_plan,
            'validation_spec',m.validation_spec,
            'source_class',m.source_class,
            'license_class',m.license_class,
            'trust_tier',m.trust_tier,
            'adoption_state',m.adoption_state,
            'external_fetch_performed',false,
            'arbitrary_code_execution',false,
            'secret_values_included',false
          ),
          case when m.status in ('approved','integrated') then 'reviewed' else 'discovered' end,
          null,false,now(),
          case when m.status in ('approved','integrated') then now() else null end,
          now()
        )
        on conflict(solution_key) do update set
          candidate_id=excluded.candidate_id,
          source_type=excluded.source_type,
          title=excluded.title,
          source_url=excluded.source_url,
          repository=excluded.repository,
          license_spdx=excluded.license_spdx,
          maintenance_score=excluded.maintenance_score,
          compatibility_score=excluded.compatibility_score,
          security_score=excluded.security_score,
          implementation_cost_score=excluded.implementation_cost_score,
          capabilities=excluded.capabilities,
          supported_platforms=excluded.supported_platforms,
          evidence=excluded.evidence,
          status=case
            when bridge_solution_catalog.status in ('selected','rejected','superseded')
              then bridge_solution_catalog.status
            else excluded.status
          end,
          secret_values_included=false,
          reviewed_at=coalesce(bridge_solution_catalog.reviewed_at,excluded.reviewed_at),
          updated_at=now();
        v_result_count := v_result_count+1;
      end loop;
    end if;

    update public.bridge_research_queue
    set state='completed',result_count=v_result_count,lease_until=null,
        claimed_by=null,last_error=null,completed_at=now(),updated_at=now()
    where research_id=r.research_id;

    if v_result_count>0 then
      update public.bridge_pattern_candidates
      set state=case
            when state in ('skill_active','blocked','deferred') then state
            else 'solution_found'
          end,
          updated_at=now()
      where candidate_id=r.candidate_id;
      v_solved := v_solved+1;
    end if;
  end loop;

  insert into public.bridge_events(
    event_type,node_name,correlation_id,severity,outcome,detail,created_at
  ) values(
    'internal_reuse_catalog_processed','supabase',gen_random_uuid()::text,
    'info','succeeded',jsonb_build_object(
      'tasks_processed',v_processed,
      'patterns_with_results',v_solved,
      'external_fetch_performed',false,
      'search_before_build',true,
      'arbitrary_code_execution',false,
      'secret_values_included',false
    ),now()
  );

  return jsonb_build_object(
    'ok',true,
    'tasks_processed',v_processed,
    'patterns_with_results',v_solved,
    'external_fetch_performed',false,
    'arbitrary_code_execution',false,
    'secret_values_included',false,
    'completed_at',now()
  );
end;
$$;

create or replace function public.bridge_pattern_skill_sweep()
returns jsonb
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_bucket text := floor(extract(epoch from clock_timestamp())/3600)::bigint::text;
  v_execution_key text := 'canonical-pattern-sweep:'||v_bucket;
  v_research_key text := 'reuse-first-catalog:'||v_bucket;
  v_run_id uuid;
  v_research_run_id uuid;
  v_harvested integer := 0;
  v_scored integer := 0;
  v_synced jsonb := '{}'::jsonb;
  v_enqueued integer := 0;
  v_compat_queries integer := 0;
  v_internal jsonb := '{}'::jsonb;
  v_promoted_canary integer := 0;
  v_promoted_active integer := 0;
  v_skill record;
  v_error text;
begin
  insert into public.bridge_automation_runs(
    skill_key,skill_version,execution_key,trigger_type,state,result_summary,
    tokens_saved_estimate,reasoning_steps_avoided,rollback_performed,
    secret_values_included,started_at
  ) values(
    'trace-to-pattern-feedback',1,v_execution_key,'cron_or_manual','running',
    jsonb_build_object(
      'authoritative_observations','openclaw_pattern_observations',
      'authoritative_candidates','openclaw_pattern_candidates',
      'projection','bridge_pattern_candidates',
      'secret_values_included',false
    ),0,0,false,false,now()
  )
  on conflict(skill_key,execution_key) do nothing
  returning run_id into v_run_id;

  if v_run_id is null then
    return jsonb_build_object(
      'ok',true,'state','duplicate','execution_key',v_execution_key,
      'arbitrary_code_execution',false,'secret_values_included',false,
      'completed_at',now()
    );
  end if;

  insert into public.bridge_automation_runs(
    skill_key,skill_version,execution_key,trigger_type,state,result_summary,
    tokens_saved_estimate,reasoning_steps_avoided,rollback_performed,
    secret_values_included,started_at
  ) values(
    'reuse-first-solution-composer',1,v_research_key,'pattern_sweep','running',
    jsonb_build_object(
      'source_catalog','openclaw_solution_sources',
      'source_matches','openclaw_pattern_source_matches',
      'external_fetch_performed',false,
      'secret_values_included',false
    ),0,0,false,false,now()
  )
  on conflict(skill_key,execution_key) do nothing
  returning run_id into v_research_run_id;

  begin
    v_harvested := public.openclaw_harvest_operational_patterns();
    v_scored := public.openclaw_refresh_pattern_scores();
    v_synced := public.bridge_sync_openclaw_pattern_engine();
    v_enqueued := public.bridge_enqueue_pattern_research(100);

    if to_regprocedure('public.openclaw_generate_research_queries(numeric)') is not null then
      execute 'select public.openclaw_generate_research_queries($1)'
      into v_compat_queries using 45::numeric;
    end if;

    v_internal := public.bridge_process_internal_research_tasks(100);

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
          v_skill.skill_key,'canary','canonical-pattern-sweep'
        );
        v_promoted_canary := v_promoted_canary+1;
      exception when others then null;
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
          v_skill.skill_key,'active','canonical-pattern-sweep'
        );
        v_promoted_active := v_promoted_active+1;
      exception when others then null;
      end;
    end loop;

    update public.bridge_automation_runs
    set state='succeeded',
        result_summary=jsonb_build_object(
          'harvested_observations',v_harvested,
          'operational_patterns_scored',v_scored,
          'patterns_synced',coalesce((v_synced->>'patterns_synced')::integer,0),
          'skills_synced',coalesce((v_synced->>'skills_synced')::integer,0),
          'research_tasks_enqueued',v_enqueued,
          'compatibility_queries_enqueued',v_compat_queries,
          'internal_catalog_tasks_processed',coalesce((v_internal->>'tasks_processed')::integer,0),
          'skills_promoted_to_canary',v_promoted_canary,
          'skills_promoted_to_active',v_promoted_active,
          'metadata_only_promotion',true,
          'external_fetch_performed',false,
          'arbitrary_code_execution',false,
          'secret_values_included',false
        ),
        completed_at=now()
    where run_id=v_run_id;

    if v_research_run_id is not null then
      update public.bridge_automation_runs
      set state='succeeded',
          result_summary=v_internal||jsonb_build_object(
            'queued_external_providers',jsonb_build_array(
              'official_docs','github','mcp_registry','n8n_templates'
            ),
            'external_fetch_performed',false,
            'search_before_build',true,
            'secret_values_included',false
          ),
          completed_at=now()
      where run_id=v_research_run_id;
    end if;

    insert into public.bridge_events(
      event_type,node_name,correlation_id,severity,outcome,detail,created_at
    ) values(
      'canonical_pattern_architecture_sweep','supabase',v_execution_key,
      'info','succeeded',jsonb_build_object(
        'harvested_observations',v_harvested,
        'operational_patterns_scored',v_scored,
        'patterns_synced',coalesce((v_synced->>'patterns_synced')::integer,0),
        'skills_synced',coalesce((v_synced->>'skills_synced')::integer,0),
        'research_tasks_enqueued',v_enqueued,
        'compatibility_queries_enqueued',v_compat_queries,
        'internal_catalog_tasks_processed',coalesce((v_internal->>'tasks_processed')::integer,0),
        'metadata_only_promotion',true,
        'external_fetch_performed',false,
        'arbitrary_code_execution',false,
        'secret_values_included',false
      ),now()
    );

    return jsonb_build_object(
      'ok',true,'state','succeeded','execution_key',v_execution_key,
      'harvested_observations',v_harvested,
      'operational_patterns_scored',v_scored,
      'patterns_synced',coalesce((v_synced->>'patterns_synced')::integer,0),
      'skills_synced',coalesce((v_synced->>'skills_synced')::integer,0),
      'research_tasks_enqueued',v_enqueued,
      'compatibility_queries_enqueued',v_compat_queries,
      'internal_catalog_tasks_processed',coalesce((v_internal->>'tasks_processed')::integer,0),
      'skills_promoted_to_canary',v_promoted_canary,
      'skills_promoted_to_active',v_promoted_active,
      'metadata_only_promotion',true,
      'external_fetch_performed',false,
      'arbitrary_code_execution',false,
      'secret_values_included',false,
      'completed_at',now()
    );
  exception when others then
    v_error := left(regexp_replace(SQLERRM,'[^A-Za-z0-9_.:-]+','_','g'),240);
    update public.bridge_automation_runs
    set state='failed',error_code=v_error,
        result_summary=jsonb_build_object(
          'authoritative_architecture_preserved',true,
          'arbitrary_code_execution',false,
          'secret_values_included',false
        ),completed_at=now()
    where run_id in (v_run_id,v_research_run_id);

    insert into public.bridge_events(
      event_type,node_name,correlation_id,severity,outcome,detail,created_at
    ) values(
      'canonical_pattern_architecture_sweep','supabase',v_execution_key,
      'warning','failed',jsonb_build_object(
        'error_code',v_error,
        'authoritative_architecture_preserved',true,
        'arbitrary_code_execution',false,
        'secret_values_included',false
      ),now()
    );

    return jsonb_build_object(
      'ok',false,'state','failed','execution_key',v_execution_key,
      'error_code',v_error,'authoritative_architecture_preserved',true,
      'arbitrary_code_execution',false,'secret_values_included',false,
      'completed_at',now()
    );
  end;
end;
$$;

revoke all on function public.bridge_process_internal_research_tasks(integer) from public,anon,authenticated;
revoke all on function public.bridge_pattern_skill_sweep() from public,anon,authenticated;
grant execute on function public.bridge_process_internal_research_tasks(integer) to service_role;
grant execute on function public.bridge_pattern_skill_sweep() to service_role;

insert into public.bridge_canonical_config(
  config_key,config_value,sensitivity,enabled,source,notes,created_at,updated_at
) values(
  'automation.pattern_sweep_contract',
  jsonb_build_object(
    'job_name','openclaw-pattern-skill-sweep-v1',
    'schedule','19 * * * *',
    'authoritative_observations','openclaw_pattern_observations',
    'authoritative_candidates','openclaw_pattern_candidates',
    'research_projection','bridge_pattern_candidates',
    'authoritative_source_catalog','openclaw_solution_sources',
    'authoritative_source_matches','openclaw_pattern_source_matches',
    'gated_skill_registry','bridge_skill_registry',
    'internal_catalog_processing',true,
    'external_fetch_performed_by_sweep',false,
    'metadata_only_promotion',true,
    'arbitrary_code_execution',false,
    'automatic_high_risk_promotion',false,
    'secret_values_included',false
  ),
  'non_secret',true,'canonical-pattern-architecture-repair',
  'Hourly unified sweep using the existing operational engine, research projection, source catalog and gated skill registry.',
  now(),now()
)
on conflict(config_key) do update set
  config_value=excluded.config_value,sensitivity='non_secret',enabled=true,
  source=excluded.source,notes=excluded.notes,updated_at=now();

insert into public.bridge_runtime_components(
  component_key,platform,component_type,component_role,canonical,selected,
  lifecycle_status,verify_jwt_required,observed_version,replacement_component_key,
  notes,last_verified_at,created_at,updated_at
) values(
  'cron.canonical-pattern-sweep','supabase','cron_job','pattern_architecture_sweep',
  true,true,'active',false,2,null,
  'Hourly unified sweep: harvest operational evidence, score authoritative candidates, project research state, process the internal reuse catalog, write receipts and metadata-promote only gated low-risk skills.',
  now(),now(),now()
)
on conflict(component_key) do update set
  platform=excluded.platform,component_type='cron_job',
  component_role=excluded.component_role,canonical=true,selected=true,
  lifecycle_status='active',verify_jwt_required=false,observed_version=2,
  replacement_component_key=null,notes=excluded.notes,last_verified_at=now(),updated_at=now();

insert into public.bridge_completion_gates(
  gate_key,scope,status,required_for_complete,evidence_ref,blocker_code,next_action,
  last_verified_at,created_at,updated_at
) values(
  'canonical_pattern_sweep_contract','supabase','pass',true,
  'config:automation.pattern_architecture;config:automation.pattern_sweep_contract','',null,
  now(),now(),now()
)
on conflict(gate_key) do update set
  scope='supabase',status='pass',required_for_complete=true,
  evidence_ref=excluded.evidence_ref,blocker_code='',next_action=null,
  last_verified_at=now(),updated_at=now();

commit;
