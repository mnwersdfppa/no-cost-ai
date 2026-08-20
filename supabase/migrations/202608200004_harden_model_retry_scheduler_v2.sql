begin;

-- Canonical verifier: Edge passes only a SHA-256 hex digest.
drop function if exists public.bridge_verify_model_retry_worker_token(text);

create function public.bridge_verify_model_retry_worker_token(p_token_hash text)
returns boolean
language sql
stable
security definer
set search_path = public, vault, extensions, pg_temp
as $$
  select case
    when p_token_hash is null or p_token_hash !~ '^[0-9a-fA-F]{64}$' then false
    else exists (
      select 1
      from vault.decrypted_secrets
      where name='openclaw_model_retry_scheduler_token'
        and encode(digest(decrypted_secret,'sha256'),'hex')=lower(p_token_hash)
    )
  end;
$$;

revoke all on function public.bridge_verify_model_retry_worker_token(text)
  from public, anon, authenticated;
grant execute on function public.bridge_verify_model_retry_worker_token(text)
  to service_role;

-- The token remains in Vault and is sent only to the custom-auth Edge boundary.
create or replace function public.bridge_invoke_model_retry_worker()
returns bigint
language plpgsql
security definer
set search_path = public, vault, net, pg_temp
as $$
declare
  v_token text;
  v_request_id bigint;
begin
  select decrypted_secret into v_token
  from vault.decrypted_secrets
  where name='openclaw_model_retry_scheduler_token'
  order by created_at desc
  limit 1;

  if v_token is null then
    raise exception 'model_retry_scheduler_token_missing';
  end if;

  select net.http_post(
    url := 'https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/model-retry-worker',
    body := '{}'::jsonb,
    headers := jsonb_build_object(
      'content-type','application/json',
      'x-openclaw-scheduler-token',v_token,
      'user-agent','supabase-openclaw-model-retry-cron/4'
    ),
    timeout_milliseconds := 110000
  ) into v_request_id;

  return v_request_id;
end;
$$;

revoke all on function public.bridge_invoke_model_retry_worker()
  from public, anon, authenticated;
grant execute on function public.bridge_invoke_model_retry_worker()
  to service_role, postgres;

-- Remove every legacy duplicate job before registering the single canonical job.
do $$
declare
  v_job record;
begin
  for v_job in
    select jobid
    from cron.job
    where jobname in (
      'openclaw-model-retry-worker-v1',
      'openclaw-model-retry-worker-v2'
    )
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;
end $$;

select cron.schedule(
  'openclaw-model-retry-worker-v2',
  '*/2 * * * *',
  $cron$select public.bridge_invoke_model_retry_worker();$cron$
);

insert into public.bridge_canonical_config(
  config_key,config_value,sensitivity,enabled,source,notes,created_at,updated_at
) values (
  'model.retry_scheduler_auth',
  jsonb_build_object(
    'vault_secret_name','openclaw_model_retry_scheduler_token',
    'http_header','x-openclaw-scheduler-token',
    'database_rpc','bridge_verify_model_retry_worker_token',
    'rpc_input','sha256_hex_only',
    'raw_token_persisted',false,
    'raw_token_returned',false,
    'legacy_worker_token_accepted',false
  ),
  'secret_reference',true,'supabase-vault-hash-contract',
  'The scheduler secret stays in Vault. Edge passes only its SHA-256 digest to the DB verifier.',
  now(),now()
) on conflict (config_key) do update set
  config_value=excluded.config_value,
  sensitivity=excluded.sensitivity,
  enabled=true,
  source=excluded.source,
  notes=excluded.notes,
  updated_at=now();

update public.bridge_canonical_config
set config_value=coalesce(config_value,'{}'::jsonb) || jsonb_build_object(
      'schedule','*/2 * * * *',
      'canonical_cron_job','openclaw-model-retry-worker-v2',
      'legacy_cron_job_enabled',false,
      'authentication','supabase_vault_sha256_verification',
      'vault_wrapper','bridge_invoke_model_retry_worker'
    ),
    source='supabase-vault-scheduler-v2',
    notes='One canonical two-minute model-retry scheduler. Live promotion still requires positive and negative authentication E2E.',
    updated_at=now()
where config_key='model.retry_worker';

insert into public.bridge_completion_gates(
  gate_key,scope,status,required_for_complete,evidence_ref,blocker_code,
  next_action,last_verified_at,created_at,updated_at
) values (
  'server_model_retry_scheduler','supabase','pending',true,null,
  'VAULT_SCHEDULER_E2E_REQUIRED',
  'Verify the Vault wrapper returns HTTP 200 and an invalid scheduler token returns HTTP 401, then promote the gate.',
  null,now(),now()
) on conflict (gate_key) do update set
  scope='supabase',
  status=case when public.bridge_completion_gates.status='pass' then 'pass' else 'pending' end,
  required_for_complete=true,
  blocker_code=case when public.bridge_completion_gates.status='pass' then '' else 'VAULT_SCHEDULER_E2E_REQUIRED' end,
  next_action=case when public.bridge_completion_gates.status='pass' then null else excluded.next_action end,
  updated_at=now();

insert into public.bridge_events(
  event_type,node_name,correlation_id,severity,outcome,detail,created_at
) values (
  'model_retry_scheduler_v2_prepared',
  'supabase',
  'model-retry-scheduler-v2-migration',
  'info','observed',
  jsonb_build_object(
    'canonical_job','openclaw-model-retry-worker-v2',
    'schedule','*/2 * * * *',
    'vault_secret_name','openclaw_model_retry_scheduler_token',
    'db_rpc_input','sha256_hex_only',
    'legacy_jobs_removed',true,
    'raw_token_persisted',false,
    'raw_token_returned',false,
    'secret_values_included',false
  ),
  now()
);

commit;
