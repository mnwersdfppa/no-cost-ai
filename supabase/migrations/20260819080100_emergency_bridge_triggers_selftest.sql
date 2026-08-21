-- Triggers and deployment self-test for the Supabase emergency bridge.

do $$
declare
  table_name text;
begin
  for table_name in
    select unnest(array[
      'bridge_credentials','bridge_controls','bridge_permission_policies',
      'bridge_route_registry','bridge_nodes'
    ])
  loop
    execute format('drop trigger if exists %I_updated_at on public.%I', table_name, table_name);
    execute format(
      'create trigger %I_updated_at before update on public.%I for each row execute function private.set_updated_at()',
      table_name, table_name
    );
  end loop;
end;
$$;

create or replace function public.bridge_self_test()
returns jsonb
language plpgsql
security definer
set search_path=public,information_schema,pg_catalog
as $$
declare
  v_required_tables integer;
  v_rls_tables integer;
  v_unsafe_grants integer;
  v_safe_controls integer;
  v_required_policies integer;
  v_cron_active boolean;
  v_unsafe_function_grants integer;
  v_status text;
  v_checks jsonb;
begin
  select count(*) into v_required_tables
  from information_schema.tables
  where table_schema='public'
    and table_name in (
      'bridge_credentials','bridge_controls','bridge_permission_policies','bridge_route_registry',
      'bridge_nodes','bridge_events','bridge_request_ledger','bridge_deployment_receipts'
    );

  select count(*) into v_rls_tables
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in (
      'bridge_credentials','bridge_controls','bridge_permission_policies','bridge_route_registry',
      'bridge_nodes','bridge_events','bridge_request_ledger','bridge_deployment_receipts'
    )
    and c.relrowsecurity;

  select count(*) into v_unsafe_grants
  from information_schema.role_table_grants
  where table_schema='public' and table_name like 'bridge_%'
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
  where (integration='supabase_platform' and operation in ('status','heartbeat','policy_check','queue_status') and enabled=true)
     or (integration='openai' and operation='chat' and enabled=false);

  select exists(select 1 from cron.job where jobname='maintain-emergency-bridge' and active=true)
  into v_cron_active;

  select count(*) into v_unsafe_function_grants
  from information_schema.routine_privileges
  where specific_schema='public'
    and routine_name in ('bridge_record_heartbeat','bridge_policy_decision','bridge_record_event','bridge_admit_request')
    and grantee in ('anon','authenticated')
    and privilege_type='EXECUTE';

  v_status:=case when
    v_required_tables=8 and v_rls_tables=8 and v_unsafe_grants=0 and
    v_safe_controls=6 and v_required_policies=5 and v_cron_active and
    v_unsafe_function_grants=0
  then 'pass' else 'fail' end;

  v_checks:=jsonb_build_object(
    'required_tables',jsonb_build_object('expected',8,'actual',v_required_tables,'pass',v_required_tables=8),
    'rls_tables',jsonb_build_object('expected',8,'actual',v_rls_tables,'pass',v_rls_tables=8),
    'unsafe_anon_authenticated_grants',jsonb_build_object('expected',0,'actual',v_unsafe_grants,'pass',v_unsafe_grants=0),
    'safe_control_defaults',jsonb_build_object('expected',6,'actual',v_safe_controls,'pass',v_safe_controls=6),
    'required_policy_defaults',jsonb_build_object('expected',5,'actual',v_required_policies,'pass',v_required_policies=5),
    'maintenance_cron',jsonb_build_object('pass',v_cron_active),
    'unsafe_function_execute_grants',jsonb_build_object('expected',0,'actual',v_unsafe_function_grants,'pass',v_unsafe_function_grants=0),
    'secret_values_checked',false,
    'paid_provider_called',false
  );

  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values('supabase-first-emergency-bridge-v1',v_status,v_checks);
  return jsonb_build_object('status',v_status,'checks',v_checks,'generated_at',now());
end;
$$;

revoke all on function public.bridge_self_test() from public,anon,authenticated;
grant execute on function public.bridge_self_test() to postgres,service_role;
