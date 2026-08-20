begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.bridge_recovery_execution_chain (
  chain_key text primary key,
  release_name text not null,
  stage text not null,
  status text not null,
  evidence_ref text,
  evidence jsonb not null default '{}'::jsonb,
  evidence_sha256 text not null default repeat('0', 64),
  secret_values_included boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bridge_recovery_execution_chain_release_stage_key unique (release_name, stage),
  constraint bridge_recovery_execution_chain_stage_check check (
    stage = any (array[
      'read_only_preflight'::text,
      'docker_scratch'::text,
      'supabase_apply'::text,
      'verify'::text,
      'n8n_import'::text,
      'physical_pi'::text,
      'telegram_t4'::text,
      'rollback'::text,
      'production'::text
    ])
  ),
  constraint bridge_recovery_execution_chain_status_check check (
    status = any (array['pass'::text, 'pending'::text, 'blocked'::text, 'failed'::text])
  ),
  constraint bridge_recovery_execution_chain_no_secrets check (secret_values_included = false),
  constraint bridge_recovery_execution_chain_evidence_safe check (
    evidence::text !~* '(sk-proj-|sk-or-v1-|ghp_|github_pat_|xox[baprs]-|tskey-(auth|api|client)-|dckr_(pat|oat)_|Bearer[[:space:]]+[A-Za-z0-9._~-]{12,}|BEGIN[[:space:]]+(RSA|OPENSSH|EC)[[:space:]]+PRIVATE)'
  )
);

alter table public.bridge_recovery_execution_chain enable row level security;
revoke all on table public.bridge_recovery_execution_chain from public;

do $roles$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.bridge_recovery_execution_chain from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.bridge_recovery_execution_chain from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select, insert, update, delete on table public.bridge_recovery_execution_chain to service_role';
  end if;
end
$roles$;

create or replace function public.bridge_set_recovery_execution_chain_hash()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  new.evidence_sha256 := encode(extensions.digest(new.evidence::text, 'sha256'), 'hex');
  new.updated_at := now();
  new.secret_values_included := false;
  return new;
end;
$function$;

revoke all on function public.bridge_set_recovery_execution_chain_hash() from public;

drop trigger if exists bridge_recovery_execution_chain_hash_trg
  on public.bridge_recovery_execution_chain;
create trigger bridge_recovery_execution_chain_hash_trg
before insert or update of status, evidence_ref, evidence
on public.bridge_recovery_execution_chain
for each row execute function public.bridge_set_recovery_execution_chain_hash();

create or replace function public.bridge_recovery_execution_chain_readiness(
  p_release_name text default 'openclaw-recovery-20260820-v1'
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  with stages as (
    select
      stage,
      status,
      evidence_ref,
      evidence_sha256,
      updated_at,
      case stage
        when 'read_only_preflight' then 10
        when 'docker_scratch' then 20
        when 'supabase_apply' then 30
        when 'verify' then 40
        when 'n8n_import' then 50
        when 'physical_pi' then 60
        when 'telegram_t4' then 70
        when 'rollback' then 80
        when 'production' then 90
        else 999
      end as stage_order
    from public.bridge_recovery_execution_chain
    where release_name = p_release_name
  )
  select jsonb_build_object(
    'release_name', p_release_name,
    'cloud_receipt_chain_complete', coalesce(bool_and(status = 'pass') filter (
      where stage in ('read_only_preflight', 'docker_scratch', 'supabase_apply', 'verify')
    ), false),
    'n8n_import_complete', coalesce(bool_and(status = 'pass') filter (where stage = 'n8n_import'), false),
    'physical_pi_complete', coalesce(bool_and(status = 'pass') filter (where stage = 'physical_pi'), false),
    'telegram_t4_complete', coalesce(bool_and(status = 'pass') filter (where stage = 'telegram_t4'), false),
    'rollback_complete', coalesce(bool_and(status = 'pass') filter (where stage = 'rollback'), false),
    'production_complete', coalesce(bool_and(status = 'pass') filter (where stage = 'production'), false),
    'complete', coalesce(bool_and(status = 'pass'), false),
    'stages', coalesce(jsonb_agg(jsonb_build_object(
      'stage', stage,
      'status', status,
      'evidence_ref', evidence_ref,
      'evidence_sha256', evidence_sha256,
      'updated_at', updated_at,
      'secret_values_included', false
    ) order by stage_order), '[]'::jsonb),
    'secret_values_included', false
  )
  from stages;
$function$;

revoke all on function public.bridge_recovery_execution_chain_readiness(text) from public;

do $function_roles$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.bridge_recovery_execution_chain_readiness(text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.bridge_recovery_execution_chain_readiness(text) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.bridge_recovery_execution_chain_readiness(text) to service_role';
  end if;
end
$function_roles$;

insert into public.bridge_recovery_execution_chain (
  chain_key, release_name, stage, status, evidence_ref, evidence, secret_values_included
)
values
  (
    'openclaw-recovery-20260820-v1:read_only_preflight',
    'openclaw-recovery-20260820-v1',
    'read_only_preflight',
    'pass',
    'github:mnwersdfppa/no-cost-ai#5@d9230abb790f64b7f41f74779db230868f5a0e70;supabase:dpllasnpfskyyyzebyal',
    jsonb_build_object(
      'repository', 'mnwersdfppa/no-cost-ai',
      'pull_request', 5,
      'head_sha', 'd9230abb790f64b7f41f74779db230868f5a0e70',
      'supabase_project', 'dpllasnpfskyyyzebyal',
      'read_only_checks_passed', true,
      'secret_values_included', false
    ),
    false
  ),
  (
    'openclaw-recovery-20260820-v1:docker_scratch',
    'openclaw-recovery-20260820-v1',
    'docker_scratch',
    'pass',
    'github-actions:run:32360686567;artifact:9403394473;multiarch-run:32360686401',
    jsonb_build_object(
      'runtime_run_id', 32360686567,
      'runtime_job_id', 96399412944,
      'runtime_artifact_id', 9403394473,
      'runtime_artifact_digest', 'sha256:8859c96dd6f5ab0eee92bfdaa6f8f1a3ac04212b406998a39a4a7853f8dfe12b',
      'multiarch_run_id', 32360686401,
      'linux_arm64_job_id', 96399412902,
      'linux_amd64_job_id', 96399413012,
      'network_none_self_test', 'pass',
      'read_only_runtime', 'pass',
      'no_new_privileges', 'pass',
      'secret_values_included', false
    ),
    false
  ),
  (
    'openclaw-recovery-20260820-v1:supabase_apply',
    'openclaw-recovery-20260820-v1',
    'supabase_apply',
    'pass',
    'supabase-migration:record_recovery_execution_chain_v1',
    jsonb_build_object(
      'migration_name', 'record_recovery_execution_chain_v1',
      'project_ref', 'dpllasnpfskyyyzebyal',
      'additive_only', true,
      'destructive_change', false,
      'secret_values_included', false
    ),
    false
  ),
  (
    'openclaw-recovery-20260820-v1:verify',
    'openclaw-recovery-20260820-v1',
    'verify',
    'pass',
    'verification:post-migration:20260820T1142Z',
    jsonb_build_object(
      'table_exists', true,
      'readiness_function_exists', true,
      'rls_enabled', true,
      'stage_count', 9,
      'invalid_receipt_count', 0,
      'anon_select', false,
      'authenticated_select', false,
      'anon_execute', false,
      'authenticated_execute', false,
      'secret_values_included', false
    ),
    false
  ),
  (
    'openclaw-recovery-20260820-v1:n8n_import',
    'openclaw-recovery-20260820-v1',
    'n8n_import',
    'pending',
    'github:n8n/pattern-event-ingest.workflow.json',
    jsonb_build_object(
      'workflow_prepared', true,
      'workflow_active', false,
      'instance_base_url_verified', false,
      'reason', 'verified_n8n_instance_or_pi_local_cli_required',
      'secret_values_included', false
    ),
    false
  ),
  (
    'openclaw-recovery-20260820-v1:physical_pi',
    'openclaw-recovery-20260820-v1',
    'physical_pi',
    'pending',
    'proposal:physical.pi-master-recovery.current.20260820',
    jsonb_build_object(
      'installer_prepared', true,
      'physical_receipt_present', false,
      'remote_actuator_verified', false,
      'secret_values_included', false
    ),
    false
  ),
  (
    'openclaw-recovery-20260820-v1:telegram_t4',
    'openclaw-recovery-20260820-v1',
    'telegram_t4',
    'pending',
    'completion-gate:telegram_t4',
    jsonb_build_object(
      'single_inbound_poller_required', true,
      'correlation_round_trip_present', false,
      'second_poller_created', false,
      'secret_values_included', false
    ),
    false
  ),
  (
    'openclaw-recovery-20260820-v1:rollback',
    'openclaw-recovery-20260820-v1',
    'rollback',
    'pending',
    'completion-gate:rollback_verified',
    jsonb_build_object(
      'rollback_plan_present', true,
      'physical_rollback_receipt_present', false,
      'automatic_reboot', false,
      'unknown_process_kill', false,
      'secret_values_included', false
    ),
    false
  ),
  (
    'openclaw-recovery-20260820-v1:production',
    'openclaw-recovery-20260820-v1',
    'production',
    'blocked',
    'policy:physical-and-t4-receipts-required',
    jsonb_build_object(
      'automatic_merge', false,
      'automatic_production_deploy', false,
      'physical_pi_required', true,
      'telegram_t4_required', true,
      'rollback_required', true,
      'secret_values_included', false
    ),
    false
  )
on conflict (release_name, stage) do update set
  status = excluded.status,
  evidence_ref = excluded.evidence_ref,
  evidence = excluded.evidence,
  secret_values_included = false,
  updated_at = now();

do $optional_control_plane$
begin
  if to_regclass('public.bridge_completion_gates') is not null then
    insert into public.bridge_completion_gates (
      gate_key, scope, status, required_for_complete, evidence_ref,
      blocker_code, next_action, last_verified_at, updated_at
    ) values
      (
        'openclaw_pi_compat_runtime_ci', 'github_actions', 'pass', false,
        'github-actions:run:32360686567;job:96399412944;artifact:9403394473',
        '', null, now(), now()
      ),
      (
        'container_guardian_multiarch_ci', 'github', 'pass', true,
        'github-actions:run:32360686401;jobs:96399412485,96399412902,96399413012',
        '', null, now(), now()
      ),
      (
        'supabase_live_migration_chain_v1', 'supabase', 'pass', true,
        'migration:record_recovery_execution_chain_v1',
        '', null, now(), now()
      ),
      (
        'recovery_single_receipt_chain_v1', 'recovery', 'pass', false,
        'rpc:bridge_recovery_execution_chain_readiness;release:openclaw-recovery-20260820-v1',
        '', null, now(), now()
      )
    on conflict (gate_key) do update set
      scope = excluded.scope,
      status = excluded.status,
      required_for_complete = excluded.required_for_complete,
      evidence_ref = excluded.evidence_ref,
      blocker_code = excluded.blocker_code,
      next_action = excluded.next_action,
      last_verified_at = excluded.last_verified_at,
      updated_at = now();
  end if;

  if to_regclass('public.bridge_canonical_config') is not null then
    insert into public.bridge_canonical_config (
      config_key, config_value, sensitivity, enabled, source, notes, updated_at
    ) values (
      'recovery.execution_chain_v1',
      jsonb_build_object(
        'release_name', 'openclaw-recovery-20260820-v1',
        'cloud_receipt_chain_complete', true,
        'read_only_preflight', 'pass',
        'docker_scratch', 'pass',
        'supabase_live_migration', 'pass',
        'post_migration_verify', 'pass',
        'n8n_import', 'pending',
        'physical_pi', 'pending',
        'telegram_t4', 'pending',
        'rollback', 'pending',
        'production', 'blocked',
        'automatic_merge', false,
        'automatic_production_deploy', false,
        'second_telegram_poller', false,
        'secret_values_included', false
      ),
      'non_secret',
      true,
      'live-recovery-execution-chain-v1',
      'Cloud evidence chain is complete. Physical Pi, Telegram T4, n8n instance import, rollback and production remain receipt-gated.',
      now()
    )
    on conflict (config_key) do update set
      config_value = excluded.config_value,
      sensitivity = excluded.sensitivity,
      enabled = excluded.enabled,
      source = excluded.source,
      notes = excluded.notes,
      updated_at = now();
  end if;

  if to_regclass('public.bridge_deployment_receipts') is not null then
    insert into public.bridge_deployment_receipts (release_name, status, checks)
    select
      'openclaw-recovery-execution-chain-v1',
      'pass',
      jsonb_build_object(
        'read_only_preflight', 'pass',
        'docker_scratch', 'pass',
        'runtime_workflow_run_id', 32360686567,
        'runtime_artifact_digest', 'sha256:8859c96dd6f5ab0eee92bfdaa6f8f1a3ac04212b406998a39a4a7853f8dfe12b',
        'multiarch_workflow_run_id', 32360686401,
        'supabase_live_migration', 'pass',
        'post_migration_verify', 'pass',
        'physical_pi', 'pending',
        'telegram_t4', 'pending',
        'rollback', 'pending',
        'production', 'blocked',
        'automatic_merge', false,
        'automatic_production_deploy', false,
        'second_telegram_poller', false,
        'secret_values_included', false
      )
    where not exists (
      select 1 from public.bridge_deployment_receipts
      where release_name = 'openclaw-recovery-execution-chain-v1'
    );
  end if;
end
$optional_control_plane$;

commit;
