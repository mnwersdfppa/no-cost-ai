begin;

create table if not exists public.bridge_model_health (
  model_id text primary key,
  provider text not null default 'supabase-opencode',
  health_status text not null default 'unknown'
    check (health_status in ('healthy','degraded','quarantined','unknown')),
  consecutive_successes integer not null default 0
    check (consecutive_successes >= 0),
  consecutive_failures integer not null default 0
    check (consecutive_failures >= 0),
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
    v_quarantine_until := now() + make_interval(
      secs => greatest(1, least(p_quarantine_seconds, 86400))
    );
  end if;

  insert into public.bridge_model_health(
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
    left(nullif(p_error_type,''),120),
    case
      when p_latency_ms is null then null
      else greatest(0, least(p_latency_ms,600000))
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
    last_error_type = left(nullif(p_error_type,''),120),
    last_latency_ms = case
      when p_latency_ms is null then public.bridge_model_health.last_latency_ms
      else greatest(0, least(p_latency_ms,600000))
    end,
    last_checked_at = now(),
    updated_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.bridge_record_model_result(
  text,boolean,integer,text,integer,integer
) from public, anon, authenticated;
grant execute on function public.bridge_record_model_result(
  text,boolean,integer,text,integer,integer
) to service_role;

create schema if not exists private;

create or replace function private.claim_openclaw_recovery_task(
  p_user_id uuid,
  p_lease_minutes integer default 15
)
returns setof public.openclaw_work_queue
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_id uuid;
begin
  if p_user_id is null then
    raise exception 'user id required';
  end if;

  select q.id into v_id
  from public.openclaw_work_queue q
  where q.task_type in (
      'pi_supabase_auth_model_recovery',
      'worker_liveness_guardian',
      'telegram_model_failover_repair'
    )
    and q.attempts < q.max_attempts
    and q.not_before <= now()
    and (
      q.status = 'queued'
      or (q.status = 'claimed' and q.lease_until is not null and q.lease_until < now())
    )
  order by
    case q.task_type
      when 'pi_supabase_auth_model_recovery' then 0
      when 'worker_liveness_guardian' then 1
      when 'telegram_model_failover_repair' then 2
      else 9
    end,
    q.priority desc,
    q.created_at asc
  for update skip locked
  limit 1;

  if v_id is null then
    return;
  end if;

  return query
  update public.openclaw_work_queue q
  set status = 'claimed',
      claimed_by = p_user_id,
      attempts = q.attempts + 1,
      lease_until = now() + make_interval(
        mins => greatest(1, least(p_lease_minutes,60))
      ),
      updated_at = now(),
      last_error = null
  where q.id = v_id
  returning q.*;
end;
$$;

create or replace function public.claim_openclaw_recovery_task(
  p_user_id uuid,
  p_lease_minutes integer default 15
)
returns setof public.openclaw_work_queue
language sql
security definer
set search_path = private, public, pg_catalog
as $$
  select * from private.claim_openclaw_recovery_task(p_user_id,p_lease_minutes);
$$;

revoke all on function private.claim_openclaw_recovery_task(uuid,integer)
  from public, anon, authenticated;
revoke all on function public.claim_openclaw_recovery_task(uuid,integer)
  from public, anon, authenticated;
grant execute on function public.claim_openclaw_recovery_task(uuid,integer)
  to service_role;

create index if not exists openclaw_work_queue_recovery_due_idx
  on public.openclaw_work_queue (priority desc, not_before, created_at)
  where task_type in (
    'pi_supabase_auth_model_recovery',
    'worker_liveness_guardian',
    'telegram_model_failover_repair'
  ) and status in ('queued','claimed');

insert into public.bridge_runtime_components(
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
  'edge.pi-model-gateway-guardian',
  'supabase',
  'edge_function',
  'model_gateway_guardian',
  false,
  false,
  'pending_audit',
  false,
  1,
  null,
  'Scoped Pi model gateway with two immediate attempts, per-model circuit breaker, durable queue acknowledgement and no provider-secret return.',
  null,
  now(),
  now()
),
(
  'edge.pi-work-queue',
  'supabase',
  'edge_function',
  'work_queue',
  false,
  false,
  'pending_audit',
  true,
  7,
  null,
  'Scoped Pi work queue with deterministic recovery allowlist, bounded leases and secret-safe evidence.',
  null,
  now(),
  now()
)
on conflict (component_key) do nothing;

insert into public.bridge_completion_gates(
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
  'pi_model_gateway_guardian_e2e',
  'supabase',
  'not_tested',
  true,
  null,
  'GUARDIAN_E2E_REQUIRED',
  'Prove unauthorized rejection, primary output, total-failure queue acknowledgement and test cleanup before promotion.',
  null,
  now(),
  now()
),
(
  'pi_recovery_queue_api_e2e',
  'supabase',
  'not_tested',
  true,
  null,
  'RECOVERY_QUEUE_E2E_REQUIRED',
  'Prove deterministic recovery task claims, completion/failure ownership and test cleanup before promotion.',
  null,
  now(),
  now()
),
(
  'pi_recovery_queue_worker_active',
  'physical_pi',
  'pending',
  true,
  'bridge_canonical_config:pi.recovery.worker_installer',
  'PHYSICAL_PI_RECOVERY_WORKER_INSTALL_REQUIRED',
  'Run the SHA-verified recovery worker installer on the Raspberry Pi and retain its redacted systemd receipt.',
  null,
  now(),
  now()
)
on conflict (gate_key) do nothing;

insert into public.bridge_canonical_config(
  config_key,
  config_value,
  sensitivity,
  enabled,
  source,
  notes,
  created_at,
  updated_at
) values (
  'model.runtime_route',
  jsonb_build_object(
    'provider','supabase-opencode',
    'base_url','https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-model-gateway-guardian/v1',
    'api','openai-responses',
    'credential','scoped_pi_access_token',
    'primary','supabase-opencode/nemotron-3-ultra-free',
    'fallbacks',jsonb_build_array(
      'supabase-opencode/laguna-s-2.1-free',
      'supabase-opencode/deepseek-v4-flash-free',
      'supabase-opencode/mimo-v2.5-free',
      'supabase-opencode/big-pickle'
    ),
    'utility_model','supabase-opencode/mimo-v2.5-free',
    'remove_model','openrouter/nvidia/nemotron-3-ultra-550b-a55b:free',
    'paid_fallback',false,
    'single_telegram_poller',true,
    'provider_secret_location','supabase_edge_only',
    'queue_ack_on_total_failure',true,
    'max_immediate_provider_attempts',2
  ),
  'non_secret',
  true,
  'migration-default',
  'Default route; promotion and live health state require E2E evidence.',
  now(),
  now()
)
on conflict (config_key) do nothing;

commit;
