-- Completes canonical Supabase/Vercel routing metadata and self-test v2.
-- This intermediate self-test uses the single explicit deny policy name created
-- by the immediately preceding bridge policy migration.

insert into public.bridge_controls(control_key,enabled,fail_closed,reason,updated_by)
values
  ('canonical_client_config',true,true,'JWT-protected canonical client configuration endpoint is selected.','completion_review'),
  ('credential_readiness_probe',true,true,'JWT-protected non-secret credential readiness endpoint is selected.','completion_review')
on conflict(control_key) do update set
  enabled=excluded.enabled,
  fail_closed=excluded.fail_closed,
  reason=excluded.reason,
  updated_by=excluded.updated_by,
  updated_at=now();

insert into public.bridge_permission_policies(
  policy_key,integration,operation,risk_tier,enabled,approval_required,max_calls_per_hour,max_payload_bytes,notes
) values
  ('supabase.canonical_config','supabase_platform','canonical_config',0,true,false,120,8192,'Returns URL and selected publishable client key only; no server secret.'),
  ('supabase.credential_readiness','supabase_platform','credential_readiness',0,true,false,30,8192,'Returns presence booleans only; no values, prefixes, hashes or lengths.')
on conflict(integration,operation) do update set
  risk_tier=excluded.risk_tier,
  enabled=excluded.enabled,
  approval_required=excluded.approval_required,
  max_calls_per_hour=excluded.max_calls_per_hour,
  max_payload_bytes=excluded.max_payload_bytes,
  notes=excluded.notes,
  updated_at=now();

insert into public.bridge_route_registry(
  route_key,integration,route_type,endpoint_alias,endpoint_url,mode,priority,enabled,health_status,last_checked_at,notes
) values
  ('supabase.canonical_client_config','supabase_platform','edge_function','canonical-client-config','https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/canonical-client-config','read_only',5,true,'not_tested',now(),'Active with verify_jwt; unauthenticated request rejected. Authenticated Pi smoke test remains pending.'),
  ('supabase.credential_readiness','supabase_platform','edge_function','credential-readiness','https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/credential-readiness','read_only',6,true,'not_tested',now(),'Active with verify_jwt; returns non-secret presence booleans only.'),
  ('supabase.emergency_bridge','supabase_platform','edge_function','emergency-bridge','https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/emergency-bridge','read_only',10,true,'not_tested',now(),'Primary JWT-protected emergency status and policy endpoint.'),
  ('supabase.pi_work_queue','supabase_platform','edge_function','pi-work-queue','https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-work-queue','queue_only',20,true,'unknown',now(),'Existing bounded Pi work queue.')
on conflict(route_key) do update set
  integration=excluded.integration,
  route_type=excluded.route_type,
  endpoint_alias=excluded.endpoint_alias,
  endpoint_url=excluded.endpoint_url,
  mode=excluded.mode,
  priority=excluded.priority,
  enabled=excluded.enabled,
  health_status=excluded.health_status,
  last_checked_at=excluded.last_checked_at,
  notes=excluded.notes,
  updated_at=now();

create or replace function public.bridge_self_test()
returns jsonb
language plpgsql
security definer
set search_path=public,information_schema,pg_catalog
as $$
declare
  v_required_tables integer;
  v_rls_tables integer;
  v_deny_policies integer;
  v_unsafe_grants integer;
  v_safe_controls integer;
  v_canonical_controls integer;
  v_required_policies integer;
  v_required_routes integer;
  v_cron_active boolean;
  v_unsafe_function_grants integer;
  v_status text;
  v_checks jsonb;
begin
  select count(*) into v_required_tables
  from information_schema.tables
  where table_schema='public'
    and table_name in (
      'bridge_credentials','bridge_credential_aliases','bridge_controls','bridge_permission_policies',
      'bridge_route_registry','bridge_nodes','bridge_events','bridge_request_ledger','bridge_deployment_receipts'
    );

  select count(*) into v_rls_tables
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in (
      'bridge_credentials','bridge_credential_aliases','bridge_controls','bridge_permission_policies',
      'bridge_route_registry','bridge_nodes','bridge_events','bridge_request_ledger','bridge_deployment_receipts'
    )
    and c.relrowsecurity;

  select count(*) into v_deny_policies
  from pg_policies
  where schemaname='public'
    and tablename in (
      'bridge_credentials','bridge_credential_aliases','bridge_controls','bridge_permission_policies',
      'bridge_route_registry','bridge_nodes','bridge_events','bridge_request_ledger','bridge_deployment_receipts'
    )
    and policyname='bridge_explicit_deny';

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

  select count(*) into v_canonical_controls
  from public.bridge_controls
  where (control_key='supabase_modern_publishable_key' and enabled=true)
     or (control_key='supabase_legacy_anon_fallback' and enabled=false)
     or (control_key='vercel_connector_management' and enabled=true)
     or (control_key='vercel_raw_token_fallback' and enabled=false)
     or (control_key='canonical_client_config' and enabled=true)
     or (control_key='credential_readiness_probe' and enabled=true);

  select count(*) into v_required_policies
  from public.bridge_permission_policies
  where (integration='supabase_platform' and operation in (
      'status','heartbeat','policy_check','queue_status','canonical_config','credential_readiness'
    ) and enabled=true)
     or (integration='openai' and operation='chat' and enabled=false);

  select count(*) into v_required_routes
  from public.bridge_route_registry
  where route_key in (
      'supabase.canonical_client_config','supabase.credential_readiness',
      'supabase.emergency_bridge','supabase.pi_work_queue'
    ) and enabled=true;

  select exists(select 1 from cron.job where jobname='maintain-emergency-bridge' and active=true)
  into v_cron_active;

  select count(*) into v_unsafe_function_grants
  from information_schema.routine_privileges
  where specific_schema='public'
    and routine_name in ('bridge_record_heartbeat','bridge_policy_decision','bridge_record_event','bridge_admit_request')
    and grantee in ('anon','authenticated') and privilege_type='EXECUTE';

  v_status:=case when
    v_required_tables=9 and v_rls_tables=9 and v_deny_policies=9 and v_unsafe_grants=0 and
    v_safe_controls=6 and v_canonical_controls=6 and v_required_policies=7 and
    v_required_routes=4 and v_cron_active and v_unsafe_function_grants=0
  then 'pass' else 'fail' end;

  v_checks:=jsonb_build_object(
    'required_tables',jsonb_build_object('expected',9,'actual',v_required_tables,'pass',v_required_tables=9),
    'rls_tables',jsonb_build_object('expected',9,'actual',v_rls_tables,'pass',v_rls_tables=9),
    'explicit_deny_policies',jsonb_build_object('expected',9,'actual',v_deny_policies,'pass',v_deny_policies=9),
    'unsafe_anon_authenticated_grants',jsonb_build_object('expected',0,'actual',v_unsafe_grants,'pass',v_unsafe_grants=0),
    'safe_control_defaults',jsonb_build_object('expected',6,'actual',v_safe_controls,'pass',v_safe_controls=6),
    'canonical_controls',jsonb_build_object('expected',6,'actual',v_canonical_controls,'pass',v_canonical_controls=6),
    'required_policy_defaults',jsonb_build_object('expected',7,'actual',v_required_policies,'pass',v_required_policies=7),
    'required_routes',jsonb_build_object('expected',4,'actual',v_required_routes,'pass',v_required_routes=4),
    'maintenance_cron',jsonb_build_object('pass',v_cron_active),
    'unsafe_function_execute_grants',jsonb_build_object('expected',0,'actual',v_unsafe_function_grants,'pass',v_unsafe_function_grants=0),
    'secret_values_checked',false,
    'paid_provider_called',false,
    'authenticated_pi_smoke_test','pending'
  );

  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values('supabase-first-emergency-bridge-v2',v_status,v_checks);
  return jsonb_build_object('status',v_status,'checks',v_checks,'generated_at',now());
end;
$$;

revoke all on function public.bridge_self_test() from public,anon,authenticated;
grant execute on function public.bridge_self_test() to postgres,service_role;

select public.bridge_self_test();
