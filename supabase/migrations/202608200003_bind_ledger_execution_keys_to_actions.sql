begin;

do $$
begin
  if exists (
    select 1
    from pg_constraint
    where conrelid='public.bridge_request_ledger'::regclass
      and conname='bridge_request_ledger_user_id_execution_key_key'
  ) then
    alter table public.bridge_request_ledger
      drop constraint bridge_request_ledger_user_id_execution_key_key;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid='public.bridge_request_ledger'::regclass
      and conname='bridge_request_ledger_user_action_execution_key_key'
  ) then
    alter table public.bridge_request_ledger
      add constraint bridge_request_ledger_user_action_execution_key_key
      unique (user_id,action,execution_key);
  end if;
end;
$$;

create or replace function public.bridge_admit_request(
  p_user_id uuid,
  p_action text,
  p_execution_key text default null
)
returns table (
  allowed boolean,
  duplicate boolean,
  reason text,
  limit_per_hour integer,
  observed_last_hour bigint
)
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  v_role text;
  v_policy public.bridge_permission_policies;
  v_emergency_enabled boolean;
  v_existing public.bridge_request_ledger;
  v_count bigint;
  v_allowed boolean;
  v_reason text;
  v_request_id bigint;
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

  if p_execution_key is not null and length(p_execution_key)>128 then
    return query select false,false,'execution_key_too_long',0,0::bigint;
    return;
  end if;

  select enabled
  into v_emergency_enabled
  from public.bridge_controls
  where control_key='emergency_bridge';

  if coalesce(v_emergency_enabled,false)=false then
    return query select false,false,'emergency_bridge_disabled',0,0::bigint;
    return;
  end if;

  if p_execution_key is not null then
    select *
    into v_existing
    from public.bridge_request_ledger
    where user_id=p_user_id
      and action=p_action
      and execution_key=p_execution_key;

    if found then
      return query select
        v_existing.allowed,
        true,
        'duplicate_execution_key',
        0,
        0::bigint;
      return;
    end if;
  end if;

  select *
  into v_policy
  from public.bridge_permission_policies
  where integration='supabase_platform'
    and operation=p_action;

  if not found then
    return query select false,false,'unsupported_action',0,0::bigint;
    return;
  end if;

  select count(*)
  into v_count
  from public.bridge_request_ledger
  where user_id=p_user_id
    and action=p_action
    and created_at>=now()-interval '1 hour';

  if v_policy.enabled=false then
    v_allowed:=false;
    v_reason:='policy_disabled';
  elsif v_policy.max_calls_per_hour=0
     or v_count>=v_policy.max_calls_per_hour then
    v_allowed:=false;
    v_reason:='rate_limit_exceeded';
  else
    v_allowed:=true;
    v_reason:='admitted';
  end if;

  insert into public.bridge_request_ledger(
    user_id,action,execution_key,allowed,reason
  ) values (
    p_user_id,p_action,p_execution_key,v_allowed,v_reason
  )
  on conflict (user_id,action,execution_key) do nothing
  returning request_id into v_request_id;

  if p_execution_key is not null and v_request_id is null then
    select *
    into v_existing
    from public.bridge_request_ledger
    where user_id=p_user_id
      and action=p_action
      and execution_key=p_execution_key;

    return query select
      coalesce(v_existing.allowed,false),
      true,
      'duplicate_execution_key',
      v_policy.max_calls_per_hour,
      v_count;
    return;
  end if;

  return query select
    v_allowed,
    false,
    v_reason,
    v_policy.max_calls_per_hour,
    v_count;
end;
$$;

revoke all on function public.bridge_admit_request(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.bridge_admit_request(uuid,text,text)
  to service_role;

insert into public.bridge_events(
  event_type,node_name,correlation_id,severity,outcome,detail,created_at
)
select
  'bridge_action_bound_execution_keys_reconciled',
  'supabase',
  'migration-202608200003',
  'info',
  'succeeded',
  jsonb_build_object(
    'unique_scope',jsonb_build_array('user_id','action','execution_key'),
    'cross_action_collision_removed',true,
    'same_action_replay_safe',true,
    'race_safe_insert',true,
    'secret_values_included',false
  ),
  now()
where not exists (
  select 1
  from public.bridge_events
  where event_type='bridge_action_bound_execution_keys_reconciled'
    and correlation_id='migration-202608200003'
);

commit;
