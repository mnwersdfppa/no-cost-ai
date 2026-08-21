-- Connect Pi heartbeat health, safe controls and the route registry into one
-- zero-cost-first, fail-closed route decision.

alter table public.bridge_route_registry
  add column if not exists capability text not null default 'generic',
  add column if not exists min_risk_tier smallint not null default 0 check (min_risk_tier between 0 and 4),
  add column if not exists max_risk_tier smallint not null default 4 check (max_risk_tier between 0 and 4),
  add column if not exists requires_control_key text references public.bridge_controls(control_key) on update cascade on delete restrict;

create index if not exists bridge_route_registry_resolver_idx
  on public.bridge_route_registry(
    capability,enabled,priority,min_risk_tier,max_risk_tier,health_status
  );

update public.bridge_route_registry
set capability='control_plane',
    min_risk_tier=0,
    max_risk_tier=4,
    requires_control_key='supabase_control_plane'
where route_key in (
  'supabase.emergency_bridge',
  'supabase.credential_readiness',
  'supabase.pi_work_queue'
);

update public.bridge_route_registry
set capability='model_chat',
    min_risk_tier=0,
    max_risk_tier=1,
    requires_control_key='local_ollama_route'
where route_key='ollama.local';

update public.bridge_route_registry
set capability='model_chat',
    min_risk_tier=1,
    max_risk_tier=4,
    requires_control_key='phone_codex_route'
where route_key='phone.codex_oauth';

update public.bridge_route_registry
set capability='model_chat',
    min_risk_tier=0,
    max_risk_tier=4,
    requires_control_key='paid_api_fallback'
where route_key='openai.paid_api';

update public.bridge_route_registry
set capability='external_discovery',
    min_risk_tier=0,
    max_risk_tier=2,
    requires_control_key='maton_readonly'
where route_key='maton.remote_mcp';

insert into public.bridge_route_registry(
  route_key,integration,route_type,endpoint_alias,endpoint_url,mode,
  capability,min_risk_tier,max_risk_tier,requires_control_key,
  priority,enabled,health_status,notes
) values (
  'openrouter.free',
  'openrouter',
  'http_api',
  'openrouter-free-only',
  'https://openrouter.ai/api/v1',
  'free_only',
  'model_chat',
  0,
  2,
  'openrouter_free_route',
  20,
  false,
  'not_tested',
  'Free-only external route. It must never fall through to a paid model or paid API.'
) on conflict (route_key) do update set
  integration=excluded.integration,
  route_type=excluded.route_type,
  endpoint_alias=excluded.endpoint_alias,
  endpoint_url=excluded.endpoint_url,
  mode=excluded.mode,
  capability=excluded.capability,
  min_risk_tier=excluded.min_risk_tier,
  max_risk_tier=excluded.max_risk_tier,
  requires_control_key=excluded.requires_control_key,
  priority=excluded.priority,
  enabled=excluded.enabled,
  health_status=excluded.health_status,
  notes=excluded.notes,
  updated_at=now();

insert into public.bridge_permission_policies(
  policy_key,integration,operation,risk_tier,enabled,approval_required,
  max_calls_per_hour,max_payload_bytes,notes
) values (
  'supabase.resolve_route',
  'supabase_platform',
  'resolve_route',
  0,
  true,
  false,
  240,
  8192,
  'Read-only zero-cost-first route decision. No credential or provider call is performed.'
) on conflict (integration,operation) do update set
  risk_tier=excluded.risk_tier,
  enabled=true,
  approval_required=false,
  max_calls_per_hour=excluded.max_calls_per_hour,
  max_payload_bytes=excluded.max_payload_bytes,
  notes=excluded.notes,
  updated_at=now();

create or replace function public.refresh_bridge_route_health()
returns void
language plpgsql
security definer
set search_path=public,pg_catalog
as $$
declare
  v_pi public.bridge_nodes;
  v_ollama_healthy boolean;
  v_gateway_healthy boolean;
begin
  select * into v_pi
  from public.bridge_nodes
  where node_type='raspberry_pi'
  order by last_seen_at desc nulls last
  limit 1;

  if not found or v_pi.last_seen_at<now()-interval '15 minutes' then
    update public.bridge_route_registry
    set health_status='unknown',last_checked_at=now(),updated_at=now()
    where route_key='ollama.local';
    return;
  end if;

  v_ollama_healthy:=coalesce((v_pi.capabilities->>'ollama_healthy')::boolean,false);
  v_gateway_healthy:=coalesce((v_pi.capabilities->>'gateway_healthy')::boolean,false);

  update public.bridge_route_registry
  set health_status=case
        when v_ollama_healthy and v_gateway_healthy then 'healthy'
        when v_gateway_healthy then 'degraded'
        else 'blocked'
      end,
      last_checked_at=now(),
      updated_at=now()
  where route_key='ollama.local';
end;
$$;

revoke all on function public.refresh_bridge_route_health()
  from public,anon,authenticated;
grant execute on function public.refresh_bridge_route_health()
  to postgres,service_role;

create or replace function public.bridge_resolve_route(
  p_user_id uuid,
  p_capability text,
  p_risk_tier smallint default 0
)
returns table(
  route_key text,
  integration text,
  endpoint_alias text,
  route_type text,
  mode text,
  health_status text,
  priority smallint,
  decision text
)
language plpgsql
security definer
set search_path=public,auth,pg_catalog
as $$
declare
  v_role text;
begin
  select raw_app_meta_data->>'role'
  into v_role
  from auth.users
  where id=p_user_id;

  if v_role<>'pi-gateway-client' then
    return query select
      null::text,null::text,null::text,null::text,null::text,null::text,
      null::smallint,'pi_identity_required'::text;
    return;
  end if;

  if p_capability is null
     or length(p_capability)<1
     or length(p_capability)>80
     or p_risk_tier not between 0 and 4 then
    return query select
      null::text,null::text,null::text,null::text,null::text,null::text,
      null::smallint,'invalid_route_request'::text;
    return;
  end if;

  perform public.refresh_bridge_route_health();

  return query
  select
    r.route_key,
    r.integration,
    r.endpoint_alias,
    r.route_type,
    r.mode,
    r.health_status,
    r.priority,
    'route_selected'::text
  from public.bridge_route_registry r
  left join public.bridge_controls c
    on c.control_key=r.requires_control_key
  where r.capability=p_capability
    and r.enabled=true
    and p_risk_tier between r.min_risk_tier and r.max_risk_tier
    and coalesce(c.enabled,true)=true
    and (
      r.health_status in ('healthy','degraded')
      or (r.route_type='local_http' and r.health_status='unknown')
    )
    and not (
      r.integration='openai'
      and coalesce((select enabled from public.bridge_controls where control_key='paid_api_fallback'),false)=false
    )
  order by r.priority asc
  limit 1;

  if not found then
    return query select
      null::text,null::text,null::text,null::text,'disabled'::text,
      'blocked'::text,null::smallint,'stop_no_eligible_route'::text;
  end if;
end;
$$;

revoke all on function public.bridge_resolve_route(uuid,text,smallint)
  from public,anon,authenticated;
grant execute on function public.bridge_resolve_route(uuid,text,smallint)
  to service_role;

create or replace function public.maintain_emergency_bridge()
returns void
language plpgsql
security definer
set search_path=public,pg_catalog
as $$
begin
  update public.bridge_nodes
  set status='offline',updated_at=now()
  where status in ('online','degraded')
    and last_seen_at<now()-interval '15 minutes';

  update public.bridge_controls
  set enabled=false,
      reason=reason||' [expired automatically]',
      updated_by='maintenance',
      updated_at=now()
  where enabled=true
    and expires_at is not null
    and expires_at<=now();

  perform public.refresh_bridge_route_health();

  delete from public.bridge_request_ledger
  where created_at<now()-interval '30 days';

  delete from public.bridge_events
  where created_at<now()-interval '90 days';
end;
$$;

revoke all on function public.maintain_emergency_bridge()
  from public,anon,authenticated;
grant execute on function public.maintain_emergency_bridge()
  to postgres,service_role;

create or replace function public.bridge_admit_request(
  p_user_id uuid,
  p_action text,
  p_execution_key text default null
)
returns table(
  allowed boolean,
  duplicate boolean,
  reason text,
  limit_per_hour integer,
  observed_last_hour bigint
)
language plpgsql
security definer
set search_path=public,auth,pg_catalog
as $$
declare
  v_role text;
  v_operation text;
  v_policy public.bridge_permission_policies;
  v_emergency_enabled boolean;
  v_existing public.bridge_request_ledger;
  v_count bigint;
begin
  select raw_app_meta_data->>'role'
  into v_role
  from auth.users
  where id=p_user_id;

  if v_role<>'pi-gateway-client' then
    return query select false,false,'pi_identity_required',0,0::bigint;
    return;
  end if;

  if p_action is null or length(p_action)<1 or length(p_action)>80 then
    return query select false,false,'invalid_action',0,0::bigint;
    return;
  end if;

  v_operation:=case p_action
    when 'status' then 'status'
    when 'heartbeat' then 'heartbeat'
    when 'policy_check' then 'policy_check'
    when 'queue_status' then 'queue_status'
    when 'credential_readiness' then 'credential_readiness'
    when 'resolve_route' then 'resolve_route'
    else null
  end;

  if v_operation is null then
    return query select false,false,'unsupported_action',0,0::bigint;
    return;
  end if;

  select enabled into v_emergency_enabled
  from public.bridge_controls
  where control_key='emergency_bridge';

  if coalesce(v_emergency_enabled,false)=false then
    return query select false,false,'emergency_bridge_disabled',0,0::bigint;
    return;
  end if;

  if p_execution_key is not null then
    if length(p_execution_key)>128 then
      return query select false,false,'execution_key_too_long',0,0::bigint;
      return;
    end if;

    select * into v_existing
    from public.bridge_request_ledger
    where user_id=p_user_id and execution_key=p_execution_key;

    if found then
      return query select v_existing.allowed,true,'duplicate_execution_key',0,0::bigint;
      return;
    end if;
  end if;

  select * into v_policy
  from public.bridge_permission_policies
  where integration='supabase_platform' and operation=v_operation;

  if not found or v_policy.enabled=false then
    insert into public.bridge_request_ledger(
      user_id,action,execution_key,allowed,reason
    ) values (
      p_user_id,p_action,p_execution_key,false,'policy_disabled'
    );
    return query select false,false,'policy_disabled',0,0::bigint;
    return;
  end if;

  select count(*) into v_count
  from public.bridge_request_ledger
  where user_id=p_user_id
    and action=p_action
    and created_at>=now()-interval '1 hour';

  if v_policy.max_calls_per_hour=0 or v_count>=v_policy.max_calls_per_hour then
    insert into public.bridge_request_ledger(
      user_id,action,execution_key,allowed,reason
    ) values (
      p_user_id,p_action,p_execution_key,false,'rate_limit_exceeded'
    );
    return query select false,false,'rate_limit_exceeded',v_policy.max_calls_per_hour,v_count;
    return;
  end if;

  insert into public.bridge_request_ledger(
    user_id,action,execution_key,allowed,reason
  ) values (
    p_user_id,p_action,p_execution_key,true,'admitted'
  );

  return query select true,false,'admitted',v_policy.max_calls_per_hour,v_count;
end;
$$;

revoke all on function public.bridge_admit_request(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.bridge_admit_request(uuid,text,text)
  to service_role;
