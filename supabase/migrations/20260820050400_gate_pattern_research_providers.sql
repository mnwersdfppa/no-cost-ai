begin;

create or replace function public.bridge_enabled_research_providers()
returns text[]
language sql
stable
security definer
set search_path=public,pg_temp
as $$
  select coalesce(
    (
      select array_agg(value order by value)
      from public.bridge_canonical_config c,
           lateral jsonb_array_elements_text(
             case
               when jsonb_typeof(c.config_value->'enabled_providers')='array'
                 then c.config_value->'enabled_providers'
               else '["github","internal_catalog"]'::jsonb
             end
           ) value
      where c.config_key='pattern_skill.research_worker'
        and c.enabled=true
        and value in (
          'official_docs','github','mcp_registry','n8n_templates',
          'docker_hub','internal_catalog','manual'
        )
    ),
    array['github','internal_catalog']::text[]
  );
$$;

create or replace function public.bridge_reconcile_research_provider_queue()
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_enabled text[];
  v_blocked integer:=0;
  v_requeued integer:=0;
begin
  v_enabled:=public.bridge_enabled_research_providers();

  with changed as (
    update public.bridge_research_queue
    set state='blocked',
        claimed_by=null,
        lease_until=null,
        last_error='PROVIDER_WORKER_NOT_CONNECTED',
        updated_at=now()
    where state='queued'
      and not(provider=any(v_enabled))
    returning research_id
  ) select count(*) into v_blocked from changed;

  with changed as (
    update public.bridge_research_queue
    set state='queued',
        last_error=null,
        not_before=now(),
        updated_at=now()
    where state='blocked'
      and last_error='PROVIDER_WORKER_NOT_CONNECTED'
      and provider=any(v_enabled)
      and attempts<max_attempts
    returning research_id
  ) select count(*) into v_requeued from changed;

  return jsonb_build_object(
    'ok',true,
    'enabled_providers',to_jsonb(v_enabled),
    'newly_blocked',v_blocked,
    'newly_requeued',v_requeued,
    'automatic_install',false,
    'automatic_skill_activation',false,
    'secret_values_included',false,
    'completed_at',now()
  );
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
  v_enabled text[];
begin
  v_enabled:=public.bridge_enabled_research_providers();

  with candidates as (
    select candidate_id,english_query,priority_score
    from public.bridge_pattern_candidates
    where state in ('ready_for_research','researching')
      and translation_state in ('ready','verified')
      and english_query is not null
      and char_length(english_query) between 8 and 1000
      and priority_score>=45
      and risk_score<=70
    order by priority_score desc,last_seen desc
    limit greatest(1,least(coalesce(p_limit,25),100))
  ), providers(provider) as (
    select unnest(v_enabled)
  ), inserted as (
    insert into public.bridge_research_queue(
      candidate_id,provider,english_query,query_hash,state,priority,
      attempts,max_attempts,not_before,secret_values_included,created_at,updated_at
    )
    select
      c.candidate_id,p.provider,c.english_query,
      encode(extensions.digest(lower(trim(c.english_query))||'|'||p.provider,'sha256'),'hex'),
      'queued',greatest(0,least(100,round(c.priority_score)::integer)),
      0,5,now(),false,now(),now()
    from candidates c cross join providers p
    on conflict(candidate_id,provider,query_hash) do nothing
    returning candidate_id
  )
  select count(*) into v_count from inserted;

  update public.bridge_pattern_candidates c
  set state='researching',updated_at=now()
  where exists(
    select 1 from public.bridge_research_queue q
    where q.candidate_id=c.candidate_id
      and q.provider=any(v_enabled)
      and q.state in ('queued','claimed')
  ) and c.state='ready_for_research';

  return coalesce(v_count,0);
end;
$$;

revoke all on function public.bridge_enabled_research_providers() from public,anon,authenticated;
revoke all on function public.bridge_reconcile_research_provider_queue() from public,anon,authenticated;
revoke all on function public.bridge_enqueue_pattern_research(integer) from public,anon,authenticated;
grant execute on function public.bridge_enabled_research_providers() to service_role;
grant execute on function public.bridge_reconcile_research_provider_queue() to service_role;
grant execute on function public.bridge_enqueue_pattern_research(integer) to service_role;

DO $$
declare
  r record;
begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    for r in select jobid from cron.job where jobname='openclaw-pattern-provider-reconcile-v1' loop
      perform cron.unschedule(r.jobid);
    end loop;
    perform cron.schedule(
      'openclaw-pattern-provider-reconcile-v1',
      '25 * * * *',
      'select public.bridge_reconcile_research_provider_queue();'
    );
  end if;
end $$;

update public.bridge_credentials
set canonical_secret_name='Github-api-delicate-key',
    detected_aliases=array['Github-api-delicate-key','GitHub-Classi-api-key'],
    configured=true,
    validation_status='valid',
    validation_detail='Edge research is pinned to the validated least-privilege GitHub alias. The broader alias remains unselected.',
    required_scopes=array['public_repo_metadata:read','search:read'],
    read_only_default=true,
    runtime_presence=jsonb_build_object(
      'supabase_edge_env',true,
      'edge_research_alias','Github-api-delicate-key',
      'edge_research_alias_valid',true,
      'broad_alias_present',true,
      'broad_alias_selected',false,
      'automatic_scope_increase',false,
      'write_permission_tested',false,
      'credential_value_returned',false,
      'secret_values_included',false
    ),
    last_validated_at=now(),
    updated_at=now()
where integration='github';

update public.bridge_credential_aliases
set selected=(alias_key='Github-api-delicate-key'),
    notes=case
      when alias_key='Github-api-delicate-key' then
        'Selected for Supabase Edge public repository metadata research.'
      when alias_key='GitHub-Classi-api-key' then
        'Valid but intentionally unselected for Edge research because broader repository scopes were observed.'
      else notes
    end,
    updated_at=now()
where canonical_integration='github';

update public.bridge_canonical_config
set config_value=coalesce(config_value,'{}'::jsonb)||jsonb_build_object(
      'github_credential_alias','Github-api-delicate-key',
      'enabled_providers',jsonb_build_array('github','internal_catalog'),
      'github_credential_policy','required_read_capability_then_least_known_privilege',
      'broad_github_alias_selected',false,
      'automatic_scope_increase',false,
      'write_permission_tested',false,
      'secret_values_included',false
    ),
    updated_at=now()
where config_key='pattern_skill.research_worker';

select public.bridge_reconcile_research_provider_queue();

commit;
