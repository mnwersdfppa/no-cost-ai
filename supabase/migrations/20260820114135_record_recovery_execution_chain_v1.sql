-- Live-applied additive migration: 20260820114135_record_recovery_execution_chain_v1
-- Project: dpllasnpfskyyyzebyal
-- No existing rows are deleted. Physical Pi, Telegram T4, rollback, n8n activation,
-- PR merge, and Production deployment remain receipt-gated.

begin;

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
  constraint bridge_recovery_execution_chain_stage_check check (stage in (
    'read_only_preflight','docker_scratch','supabase_apply','verify','n8n_import','physical_pi','telegram_t4','rollback','production'
  )),
  constraint bridge_recovery_execution_chain_status_check check (status in ('pass','pending','blocked','failed')),
  constraint bridge_recovery_execution_chain_no_secrets check (secret_values_included = false),
  constraint bridge_recovery_execution_chain_evidence_safe check (
    evidence::text !~* '(sk-proj-|sk-or-v1-|ghp_|github_pat_|xox[baprs]-|tskey-(auth|api|client)-|dckr_(pat|oat)_|Bearer[[:space:]]+[A-Za-z0-9._~-]{12,}|BEGIN[[:space:]]+(RSA|OPENSSH|EC)[[:space:]]+PRIVATE)'
  )
);

alter table public.bridge_recovery_execution_chain enable row level security;
revoke all on table public.bridge_recovery_execution_chain from public, anon, authenticated;
grant select, insert, update, delete on table public.bridge_recovery_execution_chain to service_role;

create or replace function public.bridge_set_recovery_execution_chain_hash()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  new.evidence_sha256 := encode(extensions.digest(new.evidence::text, 'sha256'), 'hex');
  new.updated_at := now();
  new.secret_values_included := false;
  return new;
end;
$$;

revoke all on function public.bridge_set_recovery_execution_chain_hash() from public, anon, authenticated;
grant execute on function public.bridge_set_recovery_execution_chain_hash() to service_role;

drop trigger if exists bridge_recovery_execution_chain_hash_trg on public.bridge_recovery_execution_chain;
create trigger bridge_recovery_execution_chain_hash_trg
before insert or update of evidence, status, evidence_ref
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
as $$
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
    'cloud_receipt_chain_complete', coalesce(bool_and(status='pass') filter (where stage in ('read_only_preflight','docker_scratch','supabase_apply','verify')), false),
    'n8n_import_complete', coalesce(bool_and(status='pass') filter (where stage='n8n_import'), false),
    'physical_pi_complete', coalesce(bool_and(status='pass') filter (where stage='physical_pi'), false),
    'telegram_t4_complete', coalesce(bool_and(status='pass') filter (where stage='telegram_t4'), false),
    'rollback_complete', coalesce(bool_and(status='pass') filter (where stage='rollback'), false),
    'production_complete', coalesce(bool_and(status='pass') filter (where stage='production'), false),
    'complete', coalesce(bool_and(status='pass'), false),
    'stages', coalesce(jsonb_agg(jsonb_build_object(
      'stage',stage,
      'status',status,
      'evidence_ref',evidence_ref,
      'evidence_sha256',evidence_sha256,
      'updated_at',updated_at,
      'secret_values_included',false
    ) order by stage_order), '[]'::jsonb),
    'secret_values_included', false
  )
  from stages;
$$;

revoke all on function public.bridge_recovery_execution_chain_readiness(text) from public, anon, authenticated;
grant execute on function public.bridge_recovery_execution_chain_readiness(text) to service_role;

insert into public.bridge_recovery_execution_chain(
  chain_key, release_name, stage, status, evidence_ref, evidence, secret_values_included
) values
(
  'openclaw-recovery-20260820-v1:read-only-preflight',
  'openclaw-recovery-20260820-v1',
  'read_only_preflight',
  'pass',
  'github:mnwersdfppa/no-cost-ai#5@d9230abb790f64b7f41f74779db230868f5a0e70;supabase:dpllasnpfskyyyzebyal',
  jsonb_build_object(
    'github_pr',5,
    'github_head_sha','d9230abb790f64b7f41f74779db230868f5a0e70',
    'github_pr_state','open_draft',
    'current_head_workflows_verified',true,
    'supabase_project_ref','dpllasnpfskyyyzebyal',
    'database_inventory_read',true,
    'write_operation_in_preflight',false,
    'secret_values_included',false
  ),
  false
),
(
  'openclaw-recovery-20260820-v1:docker-scratch',
  'openclaw-recovery-20260820-v1',
  'docker_scratch',
  'pass',
  'github-actions:run:32360686567;artifact:9403394473;multiarch-run:32360686401',
  jsonb_build_object(
    'runtime_run_id',32360686567,
    'runtime_job_id',96399412944,
    'runtime_artifact_id',9403394473,
    'runtime_artifact_digest','sha256:8859c96dd6f5ab0eee92bfdaa6f8f1a3ac04212b406998a39a4a7853f8dfe12b',
    'image_build','pass',
    'read_only_runtime','pass',
    'network_none_self_test','pass',
    'cap_drop_all','pass',
    'no_new_privileges','pass',
    'image_user','10001:10001',
    'multiarch_run_id',32360686401,
    'linux_arm64_job_id',96399412902,
    'linux_amd64_job_id',96399413012,
    'multi_platform_oci_archive','pass',
    'provider_credentials_included',false,
    'second_telegram_poller_created',false,
    'secret_values_included',false
  ),
  false
),
(
  'openclaw-recovery-20260820-v1:supabase-apply',
  'openclaw-recovery-20260820-v1',
  'supabase_apply',
  'pass',
  'supabase-migration:record_recovery_execution_chain_v1',
  jsonb_build_object(
    'project_ref','dpllasnpfskyyyzebyal',
    'migration_name','record_recovery_execution_chain_v1',
    'migration_type','additive',
    'zero_downtime',true,
    'existing_rows_deleted',false,
    'rls_enabled',true,
    'public_access_granted',false,
    'secret_values_included',false
  ),
  false
),
(
  'openclaw-recovery-20260820-v1:verify',
  'openclaw-recovery-20260820-v1',
  'verify',
  'pending',
  'verification:post-migration-query-required',
  jsonb_build_object('verification_pending',true,'secret_values_included',false),
  false
),
(
  'openclaw-recovery-20260820-v1:n8n-import',
  'openclaw-recovery-20260820-v1',
  'n8n_import',
  'pending',
  'github:n8n/pattern-event-ingest.workflow.json',
  jsonb_build_object('workflow_prepared',true,'workflow_active',false,'verified_instance_target',false,'secret_values_included',false),
  false
),
(
  'openclaw-recovery-20260820-v1:physical-pi',
  'openclaw-recovery-20260820-v1',
  'physical_pi',
  'pending',
  'proposal:physical.pi-master-recovery.current.20260820',
  jsonb_build_object('installer_verified',true,'physical_execution_receipt',false,'remote_actuator_connected',false,'secret_values_included',false),
  false
),
(
  'openclaw-recovery-20260820-v1:telegram-t4',
  'openclaw-recovery-20260820-v1',
  'telegram_t4',
  'pending',
  'completion-gate:telegram_t4',
  jsonb_build_object('single_existing_poller_required',true,'correlation_round_trip_receipt',false,'secret_values_included',false),
  false
),
(
  'openclaw-recovery-20260820-v1:rollback',
  'openclaw-recovery-20260820-v1',
  'rollback',
  'pending',
  'completion-gate:rollback_verified',
  jsonb_build_object('non_destructive_rollback_required',true,'physical_rollback_receipt',false,'secret_values_included',false),
  false
),
(
  'openclaw-recovery-20260820-v1:production',
  'openclaw-recovery-20260820-v1',
  'production',
  'blocked',
  'policy:physical-and-t4-receipts-required',
  jsonb_build_object('pr_merge',false,'production_deploy',false,'blocker','PHYSICAL_PI_TELEGRAM_T4_AND_ROLLBACK_RECEIPTS_REQUIRED','secret_values_included',false),
  false
)
on conflict (chain_key) do update set
  status=excluded.status,
  evidence_ref=excluded.evidence_ref,
  evidence=excluded.evidence,
  secret_values_included=false,
  updated_at=now();

insert into public.bridge_completion_gates(
  gate_key,scope,status,required_for_complete,evidence_ref,blocker_code,next_action,last_verified_at,created_at,updated_at
) values
(
  'openclaw_pi_compat_runtime_ci','github_actions','pass',false,
  'github-actions:run:32360686567;job:96399412944;artifact:9403394473;digest:sha256:8859c96dd6f5ab0eee92bfdaa6f8f1a3ac04212b406998a39a4a7853f8dfe12b',
  '',null,now(),now(),now()
),
(
  'container_guardian_multiarch_ci','github','pass',true,
  'github-actions:run:32360686401;jobs:96399412485,96399412902,96399413012',
  '',null,now(),now(),now()
),
(
  'supabase_live_migration_chain_v1','supabase','pass',true,
  'supabase-migration:record_recovery_execution_chain_v1',
  '',null,now(),now(),now()
),
(
  'recovery_single_receipt_chain_v1','recovery','pending',true,
  'table:bridge_recovery_execution_chain;rpc:bridge_recovery_execution_chain_readiness',
  'POST_MIGRATION_VERIFY_REQUIRED',
  'Run the post-migration verification query and update only the verify stage after all checks pass.',null,now(),now()
)
on conflict (gate_key) do update set
  scope=excluded.scope,
  status=excluded.status,
  required_for_complete=excluded.required_for_complete,
  evidence_ref=excluded.evidence_ref,
  blocker_code=excluded.blocker_code,
  next_action=excluded.next_action,
  last_verified_at=excluded.last_verified_at,
  updated_at=now();

insert into public.bridge_canonical_config(
  config_key,config_value,sensitivity,enabled,source,notes,updated_at
) values (
  'recovery.execution_chain_v1',
  jsonb_build_object(
    'release_name','openclaw-recovery-20260820-v1',
    'stages',jsonb_build_array('read_only_preflight','docker_scratch','supabase_apply','verify','n8n_import','physical_pi','telegram_t4','rollback','production'),
    'cloud_chain_state','verify_pending',
    'physical_pi_state','pending_real_receipt',
    'telegram_t4_state','pending_real_receipt',
    'production_state','blocked_until_physical_t4_rollback',
    'automatic_merge',false,
    'automatic_production_deploy',false,
    'second_telegram_poller',false,
    'secret_values_included',false
  ),
  'non_secret',true,'supabase-live-recovery-execution-chain-v1',
  'Additive receipt chain. Cloud evidence is independent from physical Pi and Telegram completion.',now()
)
on conflict (config_key) do update set
  config_value=excluded.config_value,
  sensitivity=excluded.sensitivity,
  enabled=true,
  source=excluded.source,
  notes=excluded.notes,
  updated_at=now();

commit;
