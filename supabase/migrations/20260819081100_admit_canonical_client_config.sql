-- Give canonical-client-config the same Pi identity, admission, idempotency and
-- rate-limit boundary as the other Supabase emergency endpoints.

insert into public.bridge_permission_policies(
  policy_key,integration,operation,risk_tier,enabled,approval_required,
  max_calls_per_hour,max_payload_bytes,notes
) values (
  'supabase.canonical_client_config',
  'supabase_platform',
  'canonical_client_config',
  0,
  true,
  false,
  60,
  8192,
  'Returns client-safe canonical configuration only. Server keys, raw Vercel tokens and OAuth tokens are forbidden.'
) on conflict (integration,operation) do update set
  risk_tier=excluded.risk_tier,
  enabled=true,
  approval_required=false,
  max_calls_per_hour=excluded.max_calls_per_hour,
  max_payload_bytes=excluded.max_payload_bytes,
  notes=excluded.notes,
  updated_at=now();

insert into public.bridge_route_registry(
  route_key,integration,route_type,endpoint_alias,endpoint_url,mode,
  capability,min_risk_tier,max_risk_tier,requires_control_key,
  priority,enabled,health_status,notes,component_key
) values (
  'supabase.canonical_client_config',
  'supabase_platform',
  'edge_function',
  'canonical-client-config',
  'https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/canonical-client-config',
  'read_only',
  'control_plane',
  0,
  4,
  'supabase_control_plane',
  12,
  true,
  'not_tested',
  'Pi-JWT-protected client-safe configuration; server secret and raw Vercel token are never returned.',
  'edge.canonical-client-config'
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
  enabled=true,
  notes=excluded.notes,
  component_key=excluded.component_key,
  updated_at=now();

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
  select raw_app_meta_data->>'role' into v_role
  from auth.users where id=p_user_id;

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
    when 'canonical_client_config' then 'canonical_client_config'
    when 'resolve_route' then 'resolve_route'
    else null
  end;

  if v_operation is null then
    return query select false,false,'unsupported_action',0,0::bigint;
    return;
  end if;

  select enabled into v_emergency_enabled
  from public.bridge_controls where control_key='emergency_bridge';
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
    insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason)
    values(p_user_id,p_action,p_execution_key,false,'policy_disabled');
    return query select false,false,'policy_disabled',0,0::bigint;
    return;
  end if;

  select count(*) into v_count
  from public.bridge_request_ledger
  where user_id=p_user_id and action=p_action
    and created_at>=now()-interval '1 hour';
  if v_policy.max_calls_per_hour=0 or v_count>=v_policy.max_calls_per_hour then
    insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason)
    values(p_user_id,p_action,p_execution_key,false,'rate_limit_exceeded');
    return query select false,false,'rate_limit_exceeded',v_policy.max_calls_per_hour,v_count;
    return;
  end if;

  insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason)
  values(p_user_id,p_action,p_execution_key,true,'admitted');
  return query select true,false,'admitted',v_policy.max_calls_per_hour,v_count;
end;
$$;

revoke all on function public.bridge_admit_request(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.bridge_admit_request(uuid,text,text)
  to service_role;
