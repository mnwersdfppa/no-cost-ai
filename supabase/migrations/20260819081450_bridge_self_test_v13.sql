-- Comprehensive cloud-side self-test for the Supabase-first bridge.

create or replace function public.bridge_self_test()
returns jsonb
language plpgsql
security definer
set search_path = public, information_schema, pg_catalog
as $$
declare
  v_required_relations integer := 0;
  v_bridge_tables integer := 0;
  v_rls_tables integer := 0;
  v_unsafe_table_grants integer := 0;
  v_unsafe_function_grants integer := 0;
  v_safe_controls integer := 0;
  v_required_policies integer := 0;
  v_required_crons integer := 0;
  v_capability_count integer := 0;
  v_exportable_capabilities integer := 0;
  v_duplicate_selected integer := 0;
  v_invalid_selected integer := 0;
  v_cloud_gate_failures integer := 0;
  v_open_security_backlog integer := 0;
  v_status text;
  v_checks jsonb;
begin
  select count(*) into v_required_relations
  from unnest(array[
    'bridge_credentials','bridge_controls','bridge_permission_policies',
    'bridge_route_registry','bridge_nodes','bridge_events',
    'bridge_request_ledger','bridge_deployment_receipts',
    'bridge_capability_registry','bridge_security_backlog',
    'bridge_rollout_gates','bridge_canonical_credentials',
    'bridge_credential_aliases'
  ]) as required(name)
  where to_regclass('public.' || required.name) is not null;

  select count(*),count(*) filter(where c.relrowsecurity)
  into v_bridge_tables,v_rls_tables
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relkind in ('r','p')
    and c.relname like 'bridge_%';

  select count(*) into v_unsafe_table_grants
  from information_schema.role_table_grants
  where table_schema='public'
    and table_name like 'bridge_%'
    and grantee in ('anon','authenticated');

  select count(*) into v_unsafe_function_grants
  from information_schema.routine_privileges
  where specific_schema='public'
    and routine_name in (
      'bridge_record_heartbeat','bridge_policy_decision','bridge_record_event',
      'bridge_admit_request','bridge_self_test','refresh_bridge_security_backlog',
      'refresh_bridge_rollout_gates','refresh_github_pr5_gate',
      'token_gateway_policy_gate'
    )
    and grantee in ('anon','authenticated')
    and privilege_type='EXECUTE';

  select count(*) into v_safe_controls
  from public.bridge_controls
  where (control_key='paid_api_fallback' and enabled=false and fail_closed=true)
     or (control_key='external_write_actions' and enabled=false and fail_closed=true)
     or (control_key='phone_write_actions' and enabled=false and fail_closed=true)
     or (control_key='public_shell_execution' and enabled=false and fail_closed=true)
     or (control_key='telegram_single_poller_enforced' and enabled=true and fail_closed=true)
     or (control_key='supabase_control_plane' and enabled=true and fail_closed=true)
     or (control_key='credential_alias_ssot' and enabled=true and fail_closed=true);

  select count(*) into v_required_policies
  from public.bridge_permission_policies
  where (integration='supabase_platform'
         and operation in ('status','heartbeat','policy_check','queue_status','credential_readiness')
         and enabled=true)
     or (integration='openai' and operation='chat' and enabled=false);

  select count(*) into v_required_crons
  from cron.job
  where jobname in (
    'maintain-emergency-bridge',
    'refresh-bridge-security-backlog',
    'refresh-github-pr5-gate'
  ) and active=true;

  select count(*),count(*) filter(where credential_export_allowed=true)
  into v_capability_count,v_exportable_capabilities
  from public.bridge_capability_registry;

  select count(*) into v_duplicate_selected
  from (
    select canonical_integration
    from public.bridge_canonical_credentials
    where selected=true
    group by canonical_integration
    having count(*)>1
  ) duplicates;

  select count(*) into v_invalid_selected
  from public.bridge_canonical_credentials
  where selected=true
    and validation_status in ('invalid','blocked');

  select count(*) into v_cloud_gate_failures
  from public.bridge_rollout_gates
  where component in ('Supabase','Credentials')
    and status='fail';

  select count(*) into v_open_security_backlog
  from public.bridge_security_backlog
  where status='open';

  v_status := case
    when v_required_relations=13
     and v_bridge_tables=v_rls_tables
     and v_unsafe_table_grants=0
     and v_unsafe_function_grants=0
     and v_safe_controls=7
     and v_required_policies=6
     and v_required_crons=3
     and v_capability_count>=13
     and v_exportable_capabilities=0
     and v_duplicate_selected=0
     and v_invalid_selected=0
     and v_cloud_gate_failures=0
    then 'pass'
    else 'fail'
  end;

  v_checks := jsonb_build_object(
    'required_relations',jsonb_build_object('expected',13,'actual',v_required_relations,'pass',v_required_relations=13),
    'all_bridge_tables_rls',jsonb_build_object('tables',v_bridge_tables,'rls_tables',v_rls_tables,'pass',v_bridge_tables=v_rls_tables),
    'unsafe_anon_authenticated_grants',jsonb_build_object('expected',0,'actual',v_unsafe_table_grants,'pass',v_unsafe_table_grants=0),
    'unsafe_function_execute_grants',jsonb_build_object('expected',0,'actual',v_unsafe_function_grants,'pass',v_unsafe_function_grants=0),
    'safe_control_defaults',jsonb_build_object('expected',7,'actual',v_safe_controls,'pass',v_safe_controls=7),
    'required_policy_defaults',jsonb_build_object('expected',6,'actual',v_required_policies,'pass',v_required_policies=6),
    'required_cron_jobs',jsonb_build_object('expected',3,'actual',v_required_crons,'pass',v_required_crons=3),
    'capability_registry_entries',jsonb_build_object('minimum',13,'actual',v_capability_count,'pass',v_capability_count>=13),
    'credential_export_allowed',jsonb_build_object('expected',0,'actual',v_exportable_capabilities,'pass',v_exportable_capabilities=0),
    'duplicate_selected_credentials',jsonb_build_object('expected',0,'actual',v_duplicate_selected,'pass',v_duplicate_selected=0),
    'invalid_selected_credentials',jsonb_build_object('expected',0,'actual',v_invalid_selected,'pass',v_invalid_selected=0),
    'cloud_gate_failures',jsonb_build_object('expected',0,'actual',v_cloud_gate_failures,'pass',v_cloud_gate_failures=0),
    'open_security_backlog',v_open_security_backlog,
    'secret_values_checked',false,
    'paid_provider_called',false,
    'legacy_permissions_changed',false
  );

  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values('supabase-first-emergency-bridge-v1.3',v_status,v_checks);

  perform public.refresh_bridge_rollout_gates();

  return jsonb_build_object('status',v_status,'checks',v_checks,'generated_at',now());
end;
$$;

revoke all on function public.bridge_self_test()
  from public,anon,authenticated;
grant execute on function public.bridge_self_test()
  to postgres,service_role;

select public.bridge_self_test();
