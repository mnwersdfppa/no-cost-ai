begin;

create or replace function public.bridge_suppress_redundant_external_research_tasks()
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_suppressed integer := 0;
  v_candidates integer := 0;
begin
  with eligible as (
    select
      c.candidate_id,
      count(*) filter(
        where s.status in ('reviewed','selected')
          and coalesce(s.evidence->>'match_status','') in ('approved','integrated')
          and coalesce(s.evidence->>'trust_tier','unverified') in ('official','verified')
      )::integer as trusted_result_count
    from public.bridge_pattern_candidates c
    join public.bridge_research_queue iq
      on iq.candidate_id=c.candidate_id
     and iq.provider='internal_catalog'
     and iq.state='completed'
    left join public.bridge_solution_catalog s on s.candidate_id=c.candidate_id
    group by c.candidate_id
    having count(*) filter(
      where s.status in ('reviewed','selected')
        and coalesce(s.evidence->>'match_status','') in ('approved','integrated')
        and coalesce(s.evidence->>'trust_tier','unverified') in ('official','verified')
    ) > 0
  ), updated as (
    update public.bridge_research_queue q
    set state='completed',
        result_count=e.trusted_result_count,
        lease_until=null,
        claimed_by=null,
        last_error=null,
        completed_at=now(),
        updated_at=now()
    from eligible e
    where q.candidate_id=e.candidate_id
      and q.provider<>'internal_catalog'
      and q.state='queued'
    returning q.candidate_id
  )
  select count(*),count(distinct candidate_id)
  into v_suppressed,v_candidates
  from updated;

  insert into public.bridge_events(
    event_type,node_name,correlation_id,severity,outcome,detail,created_at
  ) values(
    'redundant_external_pattern_research_suppressed','supabase',gen_random_uuid()::text,
    'info','succeeded',jsonb_build_object(
      'tasks_suppressed',v_suppressed,
      'candidates_satisfied',v_candidates,
      'condition','internal_catalog_has_official_or_verified_approved_or_integrated_solution',
      'external_api_called',false,
      'paid_api_used',false,
      'search_before_build',true,
      'secret_values_included',false
    ),now()
  );

  return jsonb_build_object(
    'ok',true,
    'tasks_suppressed',v_suppressed,
    'candidates_satisfied',v_candidates,
    'external_api_called',false,
    'paid_api_used',false,
    'secret_values_included',false,
    'completed_at',now()
  );
end;
$$;

revoke all on function public.bridge_suppress_redundant_external_research_tasks() from public,anon,authenticated;
grant execute on function public.bridge_suppress_redundant_external_research_tasks() to service_role;

DO $$
declare
  r record;
begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    for r in select jobid from cron.job where jobname='openclaw-pattern-research-housekeeping-v1' loop
      perform cron.unschedule(r.jobid);
    end loop;
    perform cron.schedule(
      'openclaw-pattern-research-housekeeping-v1',
      '24 * * * *',
      'select public.bridge_suppress_redundant_external_research_tasks();'
    );
  end if;
end $$;

insert into public.bridge_runtime_components(
  component_key,platform,component_type,component_role,canonical,selected,
  lifecycle_status,verify_jwt_required,observed_version,replacement_component_key,
  notes,last_verified_at,created_at,updated_at
) values(
  'cron.pattern-research-housekeeping','supabase','cron_job','research_deduplication',
  true,true,'active',false,1,null,
  'Completes duplicate external research tasks when the internal official-source catalog already contains approved or integrated verified solutions. No external API or paid request is made.',
  now(),now(),now()
)
on conflict(component_key) do update set
  platform=excluded.platform,component_type='cron_job',component_role=excluded.component_role,
  canonical=true,selected=true,lifecycle_status='active',verify_jwt_required=false,
  observed_version=1,replacement_component_key=null,notes=excluded.notes,
  last_verified_at=now(),updated_at=now();

insert into public.bridge_completion_gates(
  gate_key,scope,status,required_for_complete,evidence_ref,blocker_code,next_action,
  last_verified_at,created_at,updated_at
) values(
  'pattern_research_deduplication','supabase','pass',true,
  'rpc:bridge_suppress_redundant_external_research_tasks;catalog:openclaw_solution_sources','',null,
  now(),now(),now()
)
on conflict(gate_key) do update set
  scope='supabase',status='pass',required_for_complete=true,
  evidence_ref=excluded.evidence_ref,blocker_code='',next_action=null,
  last_verified_at=now(),updated_at=now();

commit;
