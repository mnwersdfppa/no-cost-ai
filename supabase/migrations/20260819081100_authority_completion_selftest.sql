-- Extend the emergency bridge self-test with authoritative ownership and
-- completion-gate integrity. A cloud PASS must never be mistaken for physical
-- Raspberry Pi, phone, Telegram, or rollback completion.

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
  v_owner_count integer;
  v_owner_conflict_policy_count integer;
  v_telegram_owner_count integer;
  v_completion_gate_count integer;
  v_required_gate_count integer;
  v_cloud_gate_pass_count integer;
  v_unproven_pass_count integer;
  v_completion_summary_consistent boolean;
  v_paid_route_enabled integer;
  v_status text;
  v_checks jsonb;
begin
  select count(*)
  into v_required_tables
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
      'bridge_security_backlog',
      'bridge_owner_registry',
      'bridge_completion_gates'
    );

  select count(*)
  into v_rls_tables
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
      'bridge_security_backlog',
      'bridge_owner_registry',
      'bridge_completion_gates'
    )
    and c.relrowsecurity;

  select count(*)
  into v_unsafe_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name like 'bridge_%'
    and grantee in ('anon', 'authenticated');

  select count(*)
  into v_safe_controls
  from public.bridge_controls
  where (control_key = 'paid_api_fallback' and enabled = false)
     or (control_key = 'external_write_actions' and enabled = false)
     or (control_key = 'phone_write_actions' and enabled = false)
     or (control_key = 'public_shell_execution' and enabled = false)
     or (control_key = 'telegram_single_poller_enforced' and enabled = true)
     or (control_key = 'supabase_control_plane' and enabled = true);

  select count(*)
  into v_required_policies
  from public.bridge_permission_policies
  where (
    integration = 'supabase_platform'
    and operation in (
      'status',
      'heartbeat',
      'policy_check',
      'queue_status',
      'credential_readiness',
      'resolve_route'
    )
    and enabled = true
  )
  or (
    integration = 'openai'
    and operation = 'chat'
    and enabled = false
  );

  select exists(
    select 1
    from cron.job
    where jobname = 'maintain-emergency-bridge'
      and active = true
  )
  into v_maintenance_cron;

  select exists(
    select 1
    from cron.job
    where jobname = 'refresh-bridge-security-backlog'
      and active = true
  )
  into v_security_backlog_cron;

  select count(*)
  into v_unsafe_function_grants
  from information_schema.routine_privileges
  where specific_schema = 'public'
    and routine_name in (
      'bridge_record_heartbeat',
      'bridge_policy_decision',
      'bridge_record_event',
      'bridge_admit_request',
      'bridge_resolve_route',
      'bridge_mark_completion_gate',
      'refresh_bridge_route_health',
      'refresh_bridge_security_backlog'
    )
    and grantee in ('anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  select count(*)
  into v_capability_count
  from public.bridge_capability_registry;

  select count(*)
  into v_exportable_capabilities
  from public.bridge_capability_registry
  where credential_export_allowed = true;

  select count(*)
  into v_owner_count
  from public.bridge_owner_registry;

  select count(*)
  into v_owner_conflict_policy_count
  from public.bridge_owner_registry
  where conflict_policy in ('fail_closed', 'reject_duplicate_owner');

  select count(*)
  into v_telegram_owner_count
  from public.bridge_owner_registry
  where domain = 'telegram_poller'
    and owner_type = 'openclaw_gateway'
    and mode = 'single_writer'
    and conflict_policy = 'reject_duplicate_owner';

  select count(*)
  into v_completion_gate_count
  from public.bridge_completion_gates;

  select count(*)
  into v_required_gate_count
  from public.bridge_completion_gates
  where required_for_complete = true;

  select count(*)
  into v_cloud_gate_pass_count
  from public.bridge_completion_gates
  where gate_key in (
    'cloud_schema',
    'edge_functions_active',
    'safe_defaults',
    'credential_export_boundary',
    'route_resolver',
    'supabase_canonical_config'
  )
    and status = 'pass'
    and evidence_ref is not null;

  select count(*)
  into v_unproven_pass_count
  from public.bridge_completion_gates
  where required_for_complete = true
    and status = 'pass'
    and evidence_ref is null;

  select case
    when complete = true and remaining_required_gates <> 0 then false
    when complete = false and remaining_required_gates = 0 then false
    else true
  end
  into v_completion_summary_consistent
  from public.bridge_completion_summary;

  select count(*)
  into v_paid_route_enabled
  from public.bridge_route_registry
  where integration = 'openai'
    and enabled = true;

  v_status := case
    when v_required_tables = 12
     and v_rls_tables = 12
     and v_unsafe_grants = 0
     and v_safe_controls = 6
     and v_required_policies = 7
     and v_maintenance_cron
     and v_security_backlog_cron
     and v_unsafe_function_grants = 0
     and v_capability_count >= 13
     and v_exportable_capabilities = 0
     and v_owner_count >= 10
     and v_owner_conflict_policy_count = v_owner_count
     and v_telegram_owner_count = 1
     and v_completion_gate_count >= 13
     and v_required_gate_count >= 12
     and v_cloud_gate_pass_count = 6
     and v_unproven_pass_count = 0
     and v_completion_summary_consistent
     and v_paid_route_enabled = 0
    then 'pass'
    else 'fail'
  end;

  v_checks := jsonb_build_object(
    'required_tables', jsonb_build_object(
      'expected', 12,
      'actual', v_required_tables,
      'pass', v_required_tables = 12
    ),
    'rls_tables', jsonb_build_object(
      'expected', 12,
      'actual', v_rls_tables,
      'pass', v_rls_tables = 12
    ),
    'unsafe_anon_authenticated_grants', jsonb_build_object(
      'expected', 0,
      'actual', v_unsafe_grants,
      'pass', v_unsafe_grants = 0
    ),
    'safe_control_defaults', jsonb_build_object(
      'expected', 6,
      'actual', v_safe_controls,
      'pass', v_safe_controls = 6
    ),
    'required_policy_defaults', jsonb_build_object(
      'expected', 7,
      'actual', v_required_policies,
      'pass', v_required_policies = 7
    ),
    'maintenance_cron', jsonb_build_object(
      'pass', v_maintenance_cron
    ),
    'security_backlog_cron', jsonb_build_object(
      'pass', v_security_backlog_cron
    ),
    'unsafe_function_execute_grants', jsonb_build_object(
      'expected', 0,
      'actual', v_unsafe_function_grants,
      'pass', v_unsafe_function_grants = 0
    ),
    'capability_registry_entries', jsonb_build_object(
      'minimum', 13,
      'actual', v_capability_count,
      'pass', v_capability_count >= 13
    ),
    'credential_export_allowed', jsonb_build_object(
      'expected', 0,
      'actual', v_exportable_capabilities,
      'pass', v_exportable_capabilities = 0
    ),
    'authoritative_owners', jsonb_build_object(
      'minimum', 10,
      'actual', v_owner_count,
      'all_fail_closed', v_owner_conflict_policy_count = v_owner_count,
      'pass', v_owner_count >= 10
        and v_owner_conflict_policy_count = v_owner_count
    ),
    'telegram_single_owner', jsonb_build_object(
      'expected', 1,
      'actual', v_telegram_owner_count,
      'pass', v_telegram_owner_count = 1
    ),
    'completion_gates', jsonb_build_object(
      'minimum_total', 13,
      'actual_total', v_completion_gate_count,
      'minimum_required', 12,
      'actual_required', v_required_gate_count,
      'cloud_pass_expected', 6,
      'cloud_pass_actual', v_cloud_gate_pass_count,
      'unproven_passes', v_unproven_pass_count,
      'summary_consistent', v_completion_summary_consistent,
      'pass', v_completion_gate_count >= 13
        and v_required_gate_count >= 12
        and v_cloud_gate_pass_count = 6
        and v_unproven_pass_count = 0
        and v_completion_summary_consistent
    ),
    'paid_openai_routes_enabled', jsonb_build_object(
      'expected', 0,
      'actual', v_paid_route_enabled,
      'pass', v_paid_route_enabled = 0
    ),
    'secret_values_checked', false,
    'paid_provider_called', false,
    'physical_completion_claimed', false,
    'legacy_permissions_changed', false
  );

  insert into public.bridge_deployment_receipts(
    release_name,
    status,
    checks
  ) values (
    'supabase-first-emergency-bridge-v1.3',
    v_status,
    v_checks
  );

  return jsonb_build_object(
    'status', v_status,
    'checks', v_checks,
    'generated_at', now()
  );
end;
$$;

revoke all on function public.bridge_self_test()
from public, anon, authenticated;

grant execute on function public.bridge_self_test()
to postgres, service_role;
