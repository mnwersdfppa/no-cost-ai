-- Register the credential-readiness route and include all bridge tables and
-- maintenance jobs in the fail-closed deployment self-test.

insert into public.bridge_permission_policies(
  policy_key,integration,operation,risk_tier,enabled,approval_required,
  max_calls_per_hour,max_payload_bytes,notes
) values (
  'supabase.credential_readiness',
  'supabase_platform',
  'credential_readiness',
  0,
  true,
  false,
  24,
  8192,
  'Read-only fixed-name credential-presence booleans. No values, prefixes, hashes or lengths.'
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
  priority,enabled,health_status,notes
) values (
  'supabase.credential_readiness',
  'supabase_platform',
  'edge_function',
  'credential-readiness',
  'https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/credential-readiness',
  'read_only',
  15,
  true,
  'not_tested',
  'Pi-JWT-protected presence booleans only; runtime-specific credentials remain isolated.'
) on conflict (route_key) do update set
  endpoint_alias=excluded.endpoint_alias,
  endpoint_url=excluded.endpoint_url,
  mode=excluded.mode,
  priority=excluded.priority,
  enabled=true,
  notes=excluded.notes,
  updated_at=now();

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
  v_status text;
  v_checks jsonb;
begin
  select count(*) into v_required_tables
  from information_schema.tables
  where table_schema = 'public'
    and table_name in (
      'bridge_credentials',
      'bridge_controls',
      'bridge_permission_policies',
      'bridge_route_registry',
      'bridge_nodes',
      'bridge_events',
      'bridge_request_ledger',
      'bridge_deployment_receipts',
      'bridge_capability_registry',
      'bridge_security_backlog'
    );

  select count(*) into v_rls_tables
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in (
      'bridge_credentials',
      'bridge_controls',
      'bridge_permission_policies',
      'bridge_route_registry',
      'bridge_nodes',
      'bridge_events',
      'bridge_request_ledger',
      'bridge_deployment_receipts',
      'bridge_capability_registry',
      'bridge_security_backlog'
    )
    and c.relrowsecurity;

  select count(*) into v_unsafe_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
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
         and operation in ('status','heartbeat','policy_check','queue_status','credential_readiness')
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
      'bridge_record_heartbeat',
      'bridge_policy_decision',
      'bridge_record_event',
      'bridge_admit_request',
      'refresh_bridge_security_backlog'
    )
    and grantee in ('anon','authenticated')
    and privilege_type='EXECUTE';

  select count(*) into v_capability_count
  from public.bridge_capability_registry;

  select count(*) into v_exportable_capabilities
  from public.bridge_capability_registry
  where credential_export_allowed=true;

  v_status := case
    when v_required_tables=10
     and v_rls_tables=10
     and v_unsafe_grants=0
     and v_safe_controls=6
     and v_required_policies=6
     and v_maintenance_cron
     and v_security_backlog_cron
     and v_unsafe_function_grants=0
     and v_capability_count>=13
     and v_exportable_capabilities=0
    then 'pass'
    else 'fail'
  end;

  v_checks := jsonb_build_object(
    'required_tables',jsonb_build_object('expected',10,'actual',v_required_tables,'pass',v_required_tables=10),
    'rls_tables',jsonb_build_object('expected',10,'actual',v_rls_tables,'pass',v_rls_tables=10),
    'unsafe_anon_authenticated_grants',jsonb_build_object('expected',0,'actual',v_unsafe_grants,'pass',v_unsafe_grants=0),
    'safe_control_defaults',jsonb_build_object('expected',6,'actual',v_safe_controls,'pass',v_safe_controls=6),
    'required_policy_defaults',jsonb_build_object('expected',6,'actual',v_required_policies,'pass',v_required_policies=6),
    'maintenance_cron',jsonb_build_object('pass',v_maintenance_cron),
    'security_backlog_cron',jsonb_build_object('pass',v_security_backlog_cron),
    'unsafe_function_execute_grants',jsonb_build_object('expected',0,'actual',v_unsafe_function_grants,'pass',v_unsafe_function_grants=0),
    'capability_registry_entries',jsonb_build_object('minimum',13,'actual',v_capability_count,'pass',v_capability_count>=13),
    'credential_export_allowed',jsonb_build_object('expected',0,'actual',v_exportable_capabilities,'pass',v_exportable_capabilities=0),
    'secret_values_checked',false,
    'paid_provider_called',false,
    'legacy_permissions_changed',false
  );

  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values ('supabase-first-emergency-bridge-v1.2',v_status,v_checks);

  return jsonb_build_object('status',v_status,'checks',v_checks,'generated_at',now());
end;
$$;

revoke all on function public.bridge_self_test() from public,anon,authenticated;
grant execute on function public.bridge_self_test() to postgres,service_role;
