-- Complete admission coverage for the canonical client configuration and the
-- Palantir-style command center. These routes already require a Pi JWT; this
-- migration adds the shared idempotency/rate-limit ledger to every action.

update public.bridge_route_registry
set capability = 'control_plane',
    min_risk_tier = 0,
    max_risk_tier = 4,
    requires_control_key = 'supabase_control_plane',
    updated_at = now()
where route_key in (
  'supabase.canonical_client_config',
  'supabase.command_center'
);

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
set search_path = public, auth, pg_catalog
as $$
declare
  v_role text;
  v_operation text;
  v_policy public.bridge_permission_policies;
  v_emergency_enabled boolean;
  v_existing public.bridge_request_ledger;
  v_count bigint;
begin
  select raw_app_meta_data ->> 'role'
  into v_role
  from auth.users
  where id = p_user_id;

  if v_role <> 'pi-gateway-client' then
    return query select false, false, 'pi_identity_required', 0, 0::bigint;
    return;
  end if;

  if p_action is null or length(p_action) < 1 or length(p_action) > 80 then
    return query select false, false, 'invalid_action', 0, 0::bigint;
    return;
  end if;

  v_operation := case p_action
    when 'status' then 'status'
    when 'heartbeat' then 'heartbeat'
    when 'policy_check' then 'policy_check'
    when 'queue_status' then 'queue_status'
    when 'credential_readiness' then 'credential_readiness'
    when 'resolve_route' then 'resolve_route'
    when 'canonical_config' then 'canonical_config'
    when 'command_status' then 'command_status'
    when 'command_ingest' then 'command_ingest'
    when 'decision_record' then 'decision_record'
    when 'feedback_record' then 'feedback_record'
    when 'object_link' then 'object_link'
    else null
  end;

  if v_operation is null then
    return query select false, false, 'unsupported_action', 0, 0::bigint;
    return;
  end if;

  select enabled
  into v_emergency_enabled
  from public.bridge_controls
  where control_key = 'emergency_bridge';

  if coalesce(v_emergency_enabled, false) = false then
    return query select false, false, 'emergency_bridge_disabled', 0, 0::bigint;
    return;
  end if;

  if p_execution_key is not null then
    if length(p_execution_key) > 128 then
      return query select false, false, 'execution_key_too_long', 0, 0::bigint;
      return;
    end if;

    select * into v_existing
    from public.bridge_request_ledger
    where user_id = p_user_id
      and execution_key = p_execution_key;

    if found then
      return query select v_existing.allowed, true, 'duplicate_execution_key', 0, 0::bigint;
      return;
    end if;
  end if;

  select * into v_policy
  from public.bridge_permission_policies
  where integration = 'supabase_platform'
    and operation = v_operation;

  if not found or v_policy.enabled = false then
    insert into public.bridge_request_ledger(user_id, action, execution_key, allowed, reason)
    values (p_user_id, p_action, p_execution_key, false, 'policy_disabled');
    return query select false, false, 'policy_disabled', 0, 0::bigint;
    return;
  end if;

  select count(*) into v_count
  from public.bridge_request_ledger
  where user_id = p_user_id
    and action = p_action
    and created_at >= now() - interval '1 hour';

  if v_policy.max_calls_per_hour = 0
     or v_count >= v_policy.max_calls_per_hour then
    insert into public.bridge_request_ledger(user_id, action, execution_key, allowed, reason)
    values (p_user_id, p_action, p_execution_key, false, 'rate_limit_exceeded');
    return query select false, false, 'rate_limit_exceeded', v_policy.max_calls_per_hour, v_count;
    return;
  end if;

  insert into public.bridge_request_ledger(user_id, action, execution_key, allowed, reason)
  values (p_user_id, p_action, p_execution_key, true, 'admitted');

  return query select true, false, 'admitted', v_policy.max_calls_per_hour, v_count;
end;
$$;

revoke all on function public.bridge_admit_request(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.bridge_admit_request(uuid,text,text)
  to service_role;

create or replace function public.bridge_self_test()
returns jsonb
language plpgsql
security definer
set search_path = public, information_schema, pg_catalog
as $$
declare
  v_required_tables integer;
  v_rls_tables integer;
  v_unsafe_grants integer;
  v_safe_controls integer;
  v_required_policies integer;
  v_required_routes integer;
  v_paid_route_safe integer;
  v_maintenance_cron boolean;
  v_security_backlog_cron boolean;
  v_unsafe_function_grants integer;
  v_capability_count integer;
  v_exportable_capabilities integer;
  v_status text;
  v_checks jsonb;
begin
  select count(*) into v_required_tables
  from information_schema.tables
  where table_schema = 'public'
    and table_name in (
      'bridge_credentials','bridge_controls','bridge_permission_policies',
      'bridge_route_registry','bridge_nodes','bridge_events',
      'bridge_request_ledger','bridge_deployment_receipts',
      'bridge_capability_registry','bridge_security_backlog'
    );

  select count(*) into v_rls_tables
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in (
      'bridge_credentials','bridge_controls','bridge_permission_policies',
      'bridge_route_registry','bridge_nodes','bridge_events',
      'bridge_request_ledger','bridge_deployment_receipts',
      'bridge_capability_registry','bridge_security_backlog'
    )
    and c.relrowsecurity;

  select count(*) into v_unsafe_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name like 'bridge_%'
    and grantee in ('anon', 'authenticated');

  select count(*) into v_safe_controls
  from public.bridge_controls
  where (control_key = 'paid_api_fallback' and enabled = false)
     or (control_key = 'external_write_actions' and enabled = false)
     or (control_key = 'phone_write_actions' and enabled = false)
     or (control_key = 'public_shell_execution' and enabled = false)
     or (control_key = 'telegram_single_poller_enforced' and enabled = true)
     or (control_key = 'supabase_control_plane' and enabled = true);

  select count(*) into v_required_policies
  from public.bridge_permission_policies
  where (
    integration = 'supabase_platform'
    and operation in (
      'status','heartbeat','policy_check','queue_status','credential_readiness',
      'resolve_route','canonical_config','command_status','command_ingest',
      'decision_record','feedback_record','object_link'
    )
    and enabled = true
  ) or (
    integration = 'openai' and operation = 'chat' and enabled = false
  );

  select count(*) into v_required_routes
  from public.bridge_route_registry
  where route_key in (
      'supabase.canonical_client_config','supabase.command_center',
      'supabase.credential_readiness','supabase.emergency_bridge',
      'supabase.pi_work_queue'
    )
    and enabled = true
    and capability = 'control_plane'
    and requires_control_key = 'supabase_control_plane';

  select count(*) into v_paid_route_safe
  from public.bridge_route_registry
  where route_key = 'openai.paid_api'
    and enabled = false
    and mode = 'disabled'
    and requires_control_key = 'paid_api_fallback';

  select exists(select 1 from cron.job where jobname = 'maintain-emergency-bridge' and active = true)
  into v_maintenance_cron;
  select exists(select 1 from cron.job where jobname = 'refresh-bridge-security-backlog' and active = true)
  into v_security_backlog_cron;

  select count(*) into v_unsafe_function_grants
  from information_schema.routine_privileges
  where specific_schema = 'public'
    and routine_name in (
      'bridge_record_heartbeat','bridge_policy_decision','bridge_record_event',
      'bridge_admit_request','bridge_resolve_route','refresh_bridge_security_backlog'
    )
    and grantee in ('anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  select count(*) into v_capability_count from public.bridge_capability_registry;
  select count(*) into v_exportable_capabilities
  from public.bridge_capability_registry
  where credential_export_allowed = true;

  v_status := case
    when v_required_tables = 10
     and v_rls_tables = 10
     and v_unsafe_grants = 0
     and v_safe_controls = 6
     and v_required_policies = 13
     and v_required_routes = 5
     and v_paid_route_safe = 1
     and v_maintenance_cron
     and v_security_backlog_cron
     and v_unsafe_function_grants = 0
     and v_capability_count >= 13
     and v_exportable_capabilities = 0
    then 'pass'
    else 'fail'
  end;

  v_checks := jsonb_build_object(
    'required_tables', jsonb_build_object('expected',10,'actual',v_required_tables,'pass',v_required_tables=10),
    'rls_tables', jsonb_build_object('expected',10,'actual',v_rls_tables,'pass',v_rls_tables=10),
    'unsafe_anon_authenticated_grants', jsonb_build_object('expected',0,'actual',v_unsafe_grants,'pass',v_unsafe_grants=0),
    'safe_control_defaults', jsonb_build_object('expected',6,'actual',v_safe_controls,'pass',v_safe_controls=6),
    'required_policy_defaults', jsonb_build_object('expected',13,'actual',v_required_policies,'pass',v_required_policies=13),
    'control_plane_routes', jsonb_build_object('expected',5,'actual',v_required_routes,'pass',v_required_routes=5),
    'paid_route_disabled', jsonb_build_object('expected',1,'actual',v_paid_route_safe,'pass',v_paid_route_safe=1),
    'maintenance_cron', jsonb_build_object('pass',v_maintenance_cron),
    'security_backlog_cron', jsonb_build_object('pass',v_security_backlog_cron),
    'unsafe_function_execute_grants', jsonb_build_object('expected',0,'actual',v_unsafe_function_grants,'pass',v_unsafe_function_grants=0),
    'capability_registry_entries', jsonb_build_object('minimum',13,'actual',v_capability_count,'pass',v_capability_count>=13),
    'credential_export_allowed', jsonb_build_object('expected',0,'actual',v_exportable_capabilities,'pass',v_exportable_capabilities=0),
    'secret_values_checked', false,
    'paid_provider_called', false,
    'legacy_permissions_changed', true,
    'legacy_permission_change_scope', 'three empty chat prototype tables only'
  );

  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values ('supabase-first-emergency-bridge-v1.3',v_status,v_checks);

  return jsonb_build_object('status',v_status,'checks',v_checks,'generated_at',now());
end;
$$;

revoke all on function public.bridge_self_test()
  from public, anon, authenticated;
grant execute on function public.bridge_self_test()
  to postgres, service_role;
