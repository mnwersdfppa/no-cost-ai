-- Extend the Supabase emergency bridge deployment self-test with the
-- zero-cost-first route contract and route-resolver privilege boundary.

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
  v_maintenance_cron boolean;
  v_security_backlog_cron boolean;
  v_unsafe_function_grants integer;
  v_capability_count integer;
  v_exportable_capabilities integer;
  v_route_contracts integer;
  v_route_function_grants integer;
  v_status text;
  v_checks jsonb;
begin
  select count(*) into v_required_tables
  from information_schema.tables
  where table_schema='public'
    and table_name in (
      'bridge_credentials','bridge_controls','bridge_permission_policies',
      'bridge_route_registry','bridge_nodes','bridge_events',
      'bridge_request_ledger','bridge_deployment_receipts',
      'bridge_capability_registry','bridge_security_backlog'
    );

  select count(*) into v_rls_tables
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in (
      'bridge_credentials','bridge_controls','bridge_permission_policies',
      'bridge_route_registry','bridge_nodes','bridge_events',
      'bridge_request_ledger','bridge_deployment_receipts',
      'bridge_capability_registry','bridge_security_backlog'
    )
    and c.relrowsecurity;

  select count(*) into v_unsafe_grants
  from information_schema.role_table_grants
  where table_schema='public'
    and table_name like 'bridge_%'
    and grantee in ('anon','authenticated');

  select count(*) into v_safe_controls
  from public.bridge_controls
  where (control_key='paid_api_fallback' and enabled=false)
     or (control_key='external_write_actions' and enabled=false)
     or (control_key='phone_write_actions' and enabled=false)
     or (control_key='public_shell_execution' and enabled=false)
     or (control_key='telegram_single_poller_enforced' and enabled=true)
     or (control_key='supabase_control_plane' and enabled=true);

  select count(*) into v_required_policies
  from public.bridge_permission_policies
  where (integration='supabase_platform'
         and operation in (
           'status','heartbeat','policy_check','queue_status',
           'credential_readiness','resolve_route'
         )
         and enabled=true)
     or (integration='openai' and operation='chat' and enabled=false);

  select exists(
    select 1 from cron.job
    where jobname='maintain-emergency-bridge' and active=true
  ) into v_maintenance_cron;

  select exists(
    select 1 from cron.job
    where jobname='refresh-bridge-security-backlog' and active=true
  ) into v_security_backlog_cron;

  select count(*) into v_unsafe_function_grants
  from information_schema.routine_privileges
  where specific_schema='public'
    and routine_name in (
      'bridge_record_heartbeat','bridge_policy_decision','bridge_record_event',
      'bridge_admit_request','bridge_resolve_route','refresh_bridge_route_health',
      'refresh_bridge_security_backlog'
    )
    and grantee in ('anon','authenticated')
    and privilege_type='EXECUTE';

  select count(*) into v_capability_count
  from public.bridge_capability_registry;

  select count(*) into v_exportable_capabilities
  from public.bridge_capability_registry
  where credential_export_allowed=true;

  select count(*) into v_route_contracts
  from public.bridge_route_registry
  where (route_key='ollama.local'
         and integration='supabase_platform'
         and capability='model_chat'
         and mode='free_only'
         and enabled=true
         and requires_control_key='local_ollama_route')
     or (route_key='openrouter.free'
         and integration='openrouter'
         and capability='model_chat'
         and mode='free_only'
         and enabled=false
         and requires_control_key='openrouter_free_route')
     or (route_key='phone.codex_oauth'
         and integration='phone_codex_oauth'
         and capability='model_chat'
         and enabled=false
         and requires_control_key='phone_codex_route')
     or (route_key='openai.paid_api'
         and integration='openai'
         and mode='disabled'
         and enabled=false
         and requires_control_key='paid_api_fallback');

  select count(*) into v_route_function_grants
  from information_schema.routine_privileges
  where specific_schema='public'
    and routine_name='bridge_resolve_route'
    and grantee='service_role'
    and privilege_type='EXECUTE';

  v_status:=case
    when v_required_tables=10
     and v_rls_tables=10
     and v_unsafe_grants=0
     and v_safe_controls=6
     and v_required_policies=7
     and v_maintenance_cron
     and v_security_backlog_cron
     and v_unsafe_function_grants=0
     and v_capability_count>=13
     and v_exportable_capabilities=0
     and v_route_contracts=4
     and v_route_function_grants>=1
    then 'pass'
    else 'fail'
  end;

  v_checks:=jsonb_build_object(
    'required_tables',jsonb_build_object('expected',10,'actual',v_required_tables,'pass',v_required_tables=10),
    'rls_tables',jsonb_build_object('expected',10,'actual',v_rls_tables,'pass',v_rls_tables=10),
    'unsafe_anon_authenticated_grants',jsonb_build_object('expected',0,'actual',v_unsafe_grants,'pass',v_unsafe_grants=0),
    'safe_control_defaults',jsonb_build_object('expected',6,'actual',v_safe_controls,'pass',v_safe_controls=6),
    'required_policy_defaults',jsonb_build_object('expected',7,'actual',v_required_policies,'pass',v_required_policies=7),
    'maintenance_cron',jsonb_build_object('pass',v_maintenance_cron),
    'security_backlog_cron',jsonb_build_object('pass',v_security_backlog_cron),
    'unsafe_function_execute_grants',jsonb_build_object('expected',0,'actual',v_unsafe_function_grants,'pass',v_unsafe_function_grants=0),
    'capability_registry_entries',jsonb_build_object('minimum',13,'actual',v_capability_count,'pass',v_capability_count>=13),
    'credential_export_allowed',jsonb_build_object('expected',0,'actual',v_exportable_capabilities,'pass',v_exportable_capabilities=0),
    'zero_cost_route_contracts',jsonb_build_object('expected',4,'actual',v_route_contracts,'pass',v_route_contracts=4),
    'route_resolver_service_role_only',jsonb_build_object('pass',v_route_function_grants>=1),
    'secret_values_checked',false,
    'paid_provider_called',false,
    'legacy_permissions_changed',false
  );

  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values ('supabase-first-emergency-bridge-v1.3',v_status,v_checks);

  return jsonb_build_object('status',v_status,'checks',v_checks,'generated_at',now());
end;
$$;

revoke all on function public.bridge_self_test() from public,anon,authenticated;
grant execute on function public.bridge_self_test() to postgres,service_role;

do $$
declare v_result jsonb;
begin
  v_result:=public.bridge_self_test();
  if v_result->>'status'<>'pass' then
    raise exception 'emergency bridge structural self-test failed: %',v_result;
  end if;
end;
$$;
