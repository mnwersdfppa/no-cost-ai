begin;

create table if not exists public.bridge_model_health (
  model_id text primary key,
  provider text not null default 'supabase-opencode',
  health_status text not null default 'unknown'
    check (health_status in ('healthy','degraded','quarantined','unknown')),
  consecutive_successes integer not null default 0 check (consecutive_successes >= 0),
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  quarantined_until timestamptz,
  last_status_code integer,
  last_error_type text,
  last_latency_ms integer,
  last_checked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bridge_model_health enable row level security;
revoke all on table public.bridge_model_health from anon, authenticated;
grant all on table public.bridge_model_health to service_role;

create index if not exists bridge_model_health_status_quarantine_idx
  on public.bridge_model_health (health_status, quarantined_until, updated_at desc);

create or replace function public.bridge_record_model_result(
  p_model_id text,
  p_success boolean,
  p_status_code integer default null,
  p_error_type text default null,
  p_latency_ms integer default null,
  p_quarantine_seconds integer default null
)
returns public.bridge_model_health
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.bridge_model_health;
  v_quarantine_until timestamptz;
begin
  if p_model_id is null or length(trim(p_model_id)) < 1 or length(p_model_id) > 160 then
    raise exception 'invalid_model_id';
  end if;

  if p_quarantine_seconds is not null then
    v_quarantine_until := now()
      + make_interval(secs => greatest(1, least(p_quarantine_seconds, 86400)));
  end if;

  insert into public.bridge_model_health (
    model_id,
    provider,
    health_status,
    consecutive_successes,
    consecutive_failures,
    quarantined_until,
    last_status_code,
    last_error_type,
    last_latency_ms,
    last_checked_at,
    created_at,
    updated_at
  ) values (
    trim(p_model_id),
    'supabase-opencode',
    case
      when p_success then 'healthy'
      when v_quarantine_until is not null then 'quarantined'
      else 'degraded'
    end,
    case when p_success then 1 else 0 end,
    case when p_success then 0 else 1 end,
    case when p_success then null else v_quarantine_until end,
    p_status_code,
    left(nullif(p_error_type, ''), 120),
    case
      when p_latency_ms is null then null
      else greatest(0, least(p_latency_ms, 600000))
    end,
    now(),
    now(),
    now()
  )
  on conflict (model_id) do update set
    health_status = case
      when p_success then 'healthy'
      when v_quarantine_until is not null then 'quarantined'
      else 'degraded'
    end,
    consecutive_successes = case
      when p_success then public.bridge_model_health.consecutive_successes + 1
      else 0
    end,
    consecutive_failures = case
      when p_success then 0
      else public.bridge_model_health.consecutive_failures + 1
    end,
    quarantined_until = case
      when p_success then null
      when v_quarantine_until is not null then v_quarantine_until
      else public.bridge_model_health.quarantined_until
    end,
    last_status_code = p_status_code,
    last_error_type = left(nullif(p_error_type, ''), 120),
    last_latency_ms = case
      when p_latency_ms is null then public.bridge_model_health.last_latency_ms
      else greatest(0, least(p_latency_ms, 600000))
    end,
    last_checked_at = now(),
    updated_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.bridge_record_model_result(
  text, boolean, integer, text, integer, integer
) from public, anon, authenticated;
grant execute on function public.bridge_record_model_result(
  text, boolean, integer, text, integer, integer
) to service_role;

-- Create the internal worker credential in Vault. The value is generated inside
-- Postgres, is never committed, and is never returned by any API response.
do $$
begin
  if not exists (
    select 1
    from vault.decrypted_secrets
    where name = 'openclaw_model_retry_worker_token'
  ) then
    perform vault.create_secret(
      encode(gen_random_bytes(32), 'hex'),
      'openclaw_model_retry_worker_token',
      'Internal pg_cron to model-retry-worker authentication token',
      null::uuid
    );
  end if;
end;
$$;

create or replace function public.bridge_verify_model_retry_worker_token(
  p_token_hash text
)
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
      where name = 'openclaw_model_retry_worker_token'
        and encode(digest(decrypted_secret, 'sha256'), 'hex') = lower(p_token_hash)
    )
  end;
$$;

revoke all on function public.bridge_verify_model_retry_worker_token(text)
  from public, anon, authenticated;
grant execute on function public.bridge_verify_model_retry_worker_token(text)
  to service_role;

create or replace function public.bridge_claim_model_retry_task(
  p_worker text,
  p_lease_minutes integer default 3
)
returns setof public.openclaw_work_queue
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_worker is null or length(trim(p_worker)) < 3 or length(p_worker) > 120 then
    raise exception 'invalid_worker';
  end if;

  return query
  with candidate as (
    select q.id
    from public.openclaw_work_queue q
    where q.task_type = 'model_request_retry'
      and q.not_before <= now()
      and q.attempts < q.max_attempts
      and (
        q.status = 'queued'
        or (
          q.status = 'claimed'
          and q.lease_until < now()
          and q.claimed_by is null
        )
      )
    order by q.priority desc, q.created_at asc
    for update skip locked
    limit 1
  )
  update public.openclaw_work_queue q
  set status = 'claimed',
      attempts = q.attempts + 1,
      lease_until = now()
        + make_interval(mins => greatest(1, least(coalesce(p_lease_minutes, 3), 15))),
      claimed_by = null,
      evidence = coalesce(q.evidence, '{}'::jsonb) || jsonb_build_object(
        'lease_owner', trim(p_worker),
        'leased_at', now(),
        'provider_secret_returned', false,
        'secret_values_included', false
      ),
      updated_at = now()
  from candidate c
  where q.id = c.id
  returning q.*;
end;
$$;

revoke all on function public.bridge_claim_model_retry_task(text, integer)
  from public, anon, authenticated;
grant execute on function public.bridge_claim_model_retry_task(text, integer)
  to service_role;

create or replace function public.bridge_claim_telegram_delivery_task(
  p_user_id uuid,
  p_lease_minutes integer default 10
)
returns setof public.openclaw_work_queue
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_user_id is null or not exists (
    select 1
    from auth.users
    where id = p_user_id
      and raw_app_meta_data->>'role' = 'pi-gateway-client'
  ) then
    raise exception 'pi_identity_required';
  end if;

  return query
  with candidate as (
    select q.id
    from public.openclaw_work_queue q
    where q.task_type = 'telegram_result_delivery'
      and q.not_before <= now()
      and q.attempts < q.max_attempts
      and (
        q.status = 'queued'
        or (q.status = 'claimed' and q.lease_until < now())
      )
    order by q.priority desc, q.created_at asc
    for update skip locked
    limit 1
  )
  update public.openclaw_work_queue q
  set status = 'claimed',
      attempts = q.attempts + 1,
      lease_until = now()
        + make_interval(mins => greatest(1, least(coalesce(p_lease_minutes, 10), 30))),
      claimed_by = p_user_id,
      evidence = coalesce(q.evidence, '{}'::jsonb) || jsonb_build_object(
        'delivery_lease_owner', p_user_id,
        'leased_at', now(),
        'secret_values_included', false
      ),
      updated_at = now()
  from candidate c
  where q.id = c.id
  returning q.*;
end;
$$;

revoke all on function public.bridge_claim_telegram_delivery_task(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.bridge_claim_telegram_delivery_task(uuid, integer)
  to service_role;

create index if not exists openclaw_work_queue_model_retry_due_idx
  on public.openclaw_work_queue (priority desc, not_before, created_at)
  where task_type = 'model_request_retry' and status in ('queued', 'claimed');

create index if not exists openclaw_work_queue_telegram_delivery_due_idx
  on public.openclaw_work_queue (priority desc, not_before, created_at)
  where task_type = 'telegram_result_delivery' and status in ('queued', 'claimed');

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
  where name = 'openclaw_model_retry_worker_token'
  limit 1;

  if v_token is null or length(v_token) < 32 then
    raise exception 'model_retry_worker_vault_token_missing';
  end if;

  select net.http_post(
    url := 'https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/model-retry-worker',
    body := '{}'::jsonb,
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-openclaw-worker-token', v_token,
      'user-agent', 'supabase-openclaw-model-retry-internal/1'
    ),
    timeout_milliseconds := 90000
  ) into v_request_id;

  v_token := null;
  return v_request_id;
end;
$$;

revoke all on function public.bridge_invoke_model_retry_worker()
  from public, anon, authenticated;
grant execute on function public.bridge_invoke_model_retry_worker()
  to service_role;

do $$
declare
  v_job record;
begin
  for v_job in
    select jobid from cron.job where jobname = 'openclaw-model-retry-worker-v1'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;
end;
$$;

select cron.schedule(
  'openclaw-model-retry-worker-v1',
  '*/5 * * * *',
  'select public.bridge_invoke_model_retry_worker();'
);

insert into public.bridge_runtime_components (
  component_key,
  platform,
  component_type,
  component_role,
  canonical,
  selected,
  lifecycle_status,
  verify_jwt_required,
  observed_version,
  replacement_component_key,
  notes,
  last_verified_at,
  created_at,
  updated_at
) values
(
  'edge.model-retry-worker',
  'supabase',
  'edge_function',
  'model_retry_worker',
  true,
  false,
  'pending_audit',
  false,
  1,
  null,
  'Vault-authenticated server worker for due model_request_retry tasks. It never starts a Telegram poller and never exports provider credentials.',
  null,
  now(),
  now()
),
(
  'edge.pi-result-delivery-queue',
  'supabase',
  'edge_function',
  'telegram_result_delivery_queue',
  true,
  false,
  'pending_audit',
  true,
  1,
  null,
  'Scoped Pi JWT queue for outbound-only Telegram result delivery.',
  null,
  now(),
  now()
),
(
  'pi.telegram-result-delivery-worker',
  'raspberry_pi',
  'local_service',
  'telegram_result_delivery_worker',
  true,
  false,
  'pending_audit',
  false,
  1,
  null,
  'Outbound-only OpenClaw message sender for completed retry results. It never starts another Telegram poller.',
  null,
  now(),
  now()
)
on conflict (component_key) do update set
  canonical = true,
  selected = false,
  lifecycle_status = 'pending_audit',
  observed_version = 1,
  replacement_component_key = null,
  notes = excluded.notes,
  last_verified_at = null,
  updated_at = now();

insert into public.bridge_completion_gates (
  gate_key,
  scope,
  status,
  required_for_complete,
  evidence_ref,
  blocker_code,
  next_action,
  last_verified_at,
  created_at,
  updated_at
) values
(
  'server_model_retry_worker_e2e',
  'supabase',
  'pending',
  true,
  null,
  'SERVER_MODEL_RETRY_WORKER_E2E_REQUIRED',
  'Prove Vault auth, unauthorized rejection, atomic claim, live retry, result persistence and delivery task creation.',
  null,
  now(),
  now()
),
(
  'pi_result_delivery_queue_e2e',
  'supabase',
  'pending',
  true,
  null,
  'PI_RESULT_DELIVERY_QUEUE_E2E_REQUIRED',
  'Prove unauthenticated rejection, deterministic pull, complete/fail ownership and cleanup.',
  null,
  now(),
  now()
),
(
  'pi_telegram_result_delivery_worker',
  'physical_pi',
  'pending',
  false,
  null,
  'PHYSICAL_PI_TELEGRAM_DELIVERY_WORKER_PENDING',
  'Install the outbound-only worker and prove openclaw message send through the existing Telegram channel.',
  null,
  now(),
  now()
)
on conflict (gate_key) do update set
  status = 'pending',
  evidence_ref = null,
  blocker_code = excluded.blocker_code,
  next_action = excluded.next_action,
  last_verified_at = null,
  updated_at = now();

insert into public.bridge_canonical_config (
  config_key,
  config_value,
  sensitivity,
  enabled,
  source,
  notes,
  created_at,
  updated_at
) values
(
  'model.retry_worker',
  jsonb_build_object(
    'edge_function', 'model-retry-worker',
    'schedule', '*/5 * * * *',
    'authentication', 'supabase_vault_hash_verification',
    'max_tasks_per_run', 1,
    'max_immediate_models', 2,
    'backoff_seconds', jsonb_build_array(120, 300, 900, 2700, 7200),
    'success_delivery_task_type', 'telegram_result_delivery',
    'raw_provider_error_stored', false,
    'provider_secret_returned', false,
    'single_telegram_poller', true
  ),
  'non_secret',
  true,
  'github-migration',
  'Server-side retries run every five minutes. Final text is queued for outbound delivery through the existing Pi/OpenClaw Telegram channel.',
  now(),
  now()
),
(
  'telegram.result_delivery_queue',
  jsonb_build_object(
    'edge_function', 'pi-result-delivery-queue',
    'task_type', 'telegram_result_delivery',
    'authentication', 'scoped_pi_jwt',
    'delivery_mode', 'openclaw_message_send',
    'poll_interval_minutes', 2,
    'outbound_only', true,
    'calls_get_updates', false,
    'uses_existing_openclaw_telegram_channel', true,
    'second_telegram_poller', false,
    'provider_secret_returned', false
  ),
  'non_secret',
  true,
  'github-migration',
  'Completed retry results are pulled by an authenticated Pi worker and sent through the existing OpenClaw Telegram channel.',
  now(),
  now()
)
on conflict (config_key) do update set
  config_value = excluded.config_value,
  sensitivity = 'non_secret',
  enabled = true,
  source = excluded.source,
  notes = excluded.notes,
  updated_at = now();

commit;
