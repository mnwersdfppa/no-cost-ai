-- OpenClaw Pattern Evolution Engine v1.1.0
-- Live reconciliation migration for the canonical public.bridge_* / public.openclaw_* control plane.
-- This intentionally does NOT create a second guardian schema or duplicate SSOT tables.

begin;

create or replace function public.openclaw_pattern_engine_bundle_readiness_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_pattern jsonb := public.bridge_pattern_skill_readiness();
  v_recovery jsonb := public.openclaw_recovery_readiness();
  v_research jsonb := public.openclaw_research_source_readiness();
  v_required_tables text[] := array[
    'bridge_pattern_observations',
    'bridge_pattern_candidates',
    'bridge_research_queue',
    'bridge_solution_catalog',
    'bridge_pattern_solution_matches',
    'bridge_skill_registry',
    'bridge_skill_versions',
    'bridge_skill_evaluations',
    'bridge_execution_receipts',
    'bridge_deployment_receipts',
    'openclaw_pattern_observations',
    'openclaw_pattern_candidates',
    'openclaw_skill_registry',
    'openclaw_skill_versions'
  ];
  v_missing_tables text[];
  v_n8n_configured boolean := false;
  v_n8n_validation text := 'missing';
  v_n8n_last_validated timestamptz;
  v_state text;
begin
  select coalesce(array_agg(required_name order by required_name), array[]::text[])
    into v_missing_tables
  from unnest(v_required_tables) as required_name
  where to_regclass(format('public.%I', required_name)) is null;

  select
    coalesce(bool_or(configured), false),
    coalesce(max(validation_status), 'missing'),
    max(last_validated_at)
  into v_n8n_configured, v_n8n_validation, v_n8n_last_validated
  from public.bridge_credentials
  where integration = 'n8n';

  v_state := case
    when cardinality(v_missing_tables) > 0 then 'BLOCKED_SCHEMA_DRIFT'
    when coalesce(v_pattern->>'state', 'UNKNOWN') = 'DEGRADED' then 'DEGRADED'
    when coalesce((v_recovery->>'physical_pi_complete')::boolean, false)
         and v_n8n_configured then 'LIVE_READY'
    when coalesce((v_recovery->>'cloud_ready')::boolean, false) then
      'LIVE_SUPABASE_RECONCILED_PI_N8N_PENDING'
    else 'LIVE_RECONCILED_PENDING_RUNTIME_EVIDENCE'
  end;

  return jsonb_build_object(
    'ok', cardinality(v_missing_tables) = 0,
    'state', v_state,
    'bundle', jsonb_build_object(
      'name', 'openclaw-pattern-engine',
      'version', '1.1.0',
      'canonical_schema', 'public.bridge_* + public.openclaw_*',
      'duplicate_guardian_schema_created', false,
      'migration_strategy', 'reconcile_existing_control_plane',
      'secret_values_included', false
    ),
    'schema', jsonb_build_object(
      'required_table_count', cardinality(v_required_tables),
      'missing_tables', to_jsonb(v_missing_tables),
      'all_required_tables_present', cardinality(v_missing_tables) = 0
    ),
    'pattern_skill', v_pattern,
    'recovery', v_recovery,
    'research_sources', v_research,
    'n8n', jsonb_build_object(
      'configured', v_n8n_configured,
      'validation_status', v_n8n_validation,
      'last_validated_at', v_n8n_last_validated,
      'template_catalog_available', true,
      'instance_target_ready', v_n8n_configured and v_n8n_validation = 'valid',
      'fallback_import_mode', 'pi_local_cli',
      'workflow_path', 'n8n/pattern-event-ingest.workflow.json',
      'automatic_activation', false,
      'secret_values_included', false
    ),
    'github', jsonb_build_object(
      'repository', 'mnwersdfppa/no-cost-ai',
      'pull_request', 5,
      'branch', 'feat/supabase-emergency-bridge-20260819',
      'draft_required', true,
      'automatic_merge', false
    ),
    'remaining_gates', coalesce((
      select jsonb_agg(gate_name order by gate_name)
      from (values
        (case when not coalesce((v_recovery->>'physical_pi_complete')::boolean, false)
          then 'physical_pi_install_and_receipts'::text else null end),
        (case when not v_n8n_configured
          then 'n8n_instance_target_or_pi_local_import'::text else null end)
      ) as gates(gate_name)
      where gate_name is not null
    ), '[]'::jsonb),
    'checked_at', now(),
    'secret_values_included', false
  );
end;
$$;

revoke all on function public.openclaw_pattern_engine_bundle_readiness_v1()
  from public, anon, authenticated;
grant execute on function public.openclaw_pattern_engine_bundle_readiness_v1()
  to service_role;

insert into public.bridge_canonical_config (
  config_key,
  config_value,
  sensitivity,
  enabled,
  source,
  notes,
  updated_at
)
values (
  'release.openclaw_pattern_engine_v1_1_0',
  jsonb_build_object(
    'bundle_name', 'openclaw-pattern-engine',
    'bundle_version', '1.1.0',
    'supabase_project_ref', 'dpllasnpfskyyyzebyal',
    'canonical_schema', 'public.bridge_* + public.openclaw_*',
    'duplicate_guardian_schema_avoided', true,
    'readiness_function', 'public.openclaw_pattern_engine_bundle_readiness_v1',
    'github_repository', 'mnwersdfppa/no-cost-ai',
    'github_pull_request', 5,
    'github_branch', 'feat/supabase-emergency-bridge-20260819',
    'n8n_template_catalog_url', 'https://api.n8n.io/api',
    'n8n_instance_target_state', 'awaiting_verified_instance_target_or_pi_local_cli',
    'n8n_workflow_path', 'n8n/pattern-event-ingest.workflow.json',
    'physical_pi_state', 'pending_install_receipts',
    'automatic_merge', false,
    'automatic_workflow_activation', false,
    'automatic_production_deploy', false,
    'secret_values_included', false
  ),
  'non_secret',
  true,
  'openclaw_pattern_engine_live_reconciliation_v1_1_0',
  'Reconciles the validated v1.1.0 bundle with the existing live bridge/openclaw control plane; does not create a parallel SSOT.',
  now()
)
on conflict (config_key) do update set
  config_value = excluded.config_value,
  sensitivity = excluded.sensitivity,
  enabled = excluded.enabled,
  source = excluded.source,
  notes = excluded.notes,
  updated_at = now();

insert into public.bridge_canonical_config (
  config_key,
  config_value,
  sensitivity,
  enabled,
  source,
  notes,
  updated_at
)
values (
  'integration.n8n_instance_target',
  jsonb_build_object(
    'state', 'awaiting_verified_instance_target_or_pi_local_cli',
    'template_catalog_is_not_instance_api', true,
    'template_catalog_base_url', 'https://api.n8n.io/api',
    'instance_api_required_for_cloud_import', true,
    'pi_local_cli_supported', true,
    'pi_local_import_command', 'n8n import:workflow --input=/opt/openclaw-pattern-engine/n8n/pattern-event-ingest.workflow.json',
    'workflow_activation_after_import', false,
    'credential_values_included', false,
    'secret_values_included', false
  ),
  'non_secret',
  true,
  'openclaw_pattern_engine_live_reconciliation_v1_1_0',
  'Separates the public n8n template catalog from the user n8n instance API and prevents the template API from being treated as an import target.',
  now()
)
on conflict (config_key) do update set
  config_value = excluded.config_value,
  sensitivity = excluded.sensitivity,
  enabled = excluded.enabled,
  source = excluded.source,
  notes = excluded.notes,
  updated_at = now();

insert into public.bridge_deployment_receipts (release_name, status, checks)
select
  'openclaw-pattern-engine-v1.1.0-live-reconciliation',
  case
    when (public.openclaw_pattern_engine_bundle_readiness_v1()->>'ok')::boolean then 'partial'
    else 'fail'
  end,
  public.openclaw_pattern_engine_bundle_readiness_v1()
where not exists (
  select 1
  from public.bridge_deployment_receipts
  where release_name = 'openclaw-pattern-engine-v1.1.0-live-reconciliation'
    and checks->'bundle'->>'version' = '1.1.0'
);

commit;
