-- Define one authoritative owner per operational domain and explicitly separate
-- cloud preparation from physical Raspberry Pi, phone, Telegram, and rollback
-- evidence. This migration is additive, fail-closed, and stores no secrets.

create table if not exists public.bridge_owner_registry (
  domain text primary key,
  owner_type text not null check (
    owner_type in (
      'supabase_edge_function',
      'supabase_database',
      'openclaw_gateway',
      'raspberry_pi',
      'vercel_project',
      'disabled'
    )
  ),
  owner_ref text not null,
  mode text not null check (
    mode in ('authoritative','single_writer','read_only','disabled','pending')
  ),
  status text not null check (
    status in ('active','degraded','blocked','pending','disabled')
  ),
  conflict_policy text not null default 'fail_closed',
  notes text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.bridge_completion_gates (
  gate_key text primary key,
  scope text not null,
  status text not null check (
    status in ('pass','partial','pending','blocked','not_tested','fail')
  ),
  required_for_complete boolean not null default true,
  evidence_ref text,
  blocker_code text,
  next_action text,
  last_verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bridge_owner_registry enable row level security;
alter table public.bridge_completion_gates enable row level security;

revoke all on table
  public.bridge_owner_registry,
  public.bridge_completion_gates
from anon, authenticated;

grant select, insert, update, delete on table
  public.bridge_owner_registry,
  public.bridge_completion_gates
to service_role;

comment on table public.bridge_owner_registry is
  'One authoritative owner per operational domain. Conflicting owners fail closed.';

comment on table public.bridge_completion_gates is
  'Separates cloud preparation from physical Pi, phone, Telegram, and rollback completion evidence.';

drop trigger if exists bridge_owner_registry_updated_at
  on public.bridge_owner_registry;
create trigger bridge_owner_registry_updated_at
before update on public.bridge_owner_registry
for each row execute function private.set_updated_at();

drop trigger if exists bridge_completion_gates_updated_at
  on public.bridge_completion_gates;
create trigger bridge_completion_gates_updated_at
before update on public.bridge_completion_gates
for each row execute function private.set_updated_at();

insert into public.bridge_owner_registry(
  domain,
  owner_type,
  owner_ref,
  mode,
  status,
  conflict_policy,
  notes
) values
  (
    'decision_ssot',
    'supabase_database',
    'command-center tables and decision ledger',
    'authoritative',
    'active',
    'fail_closed',
    'Supabase is the structured decision source of truth.'
  ),
  (
    'emergency_control',
    'supabase_edge_function',
    'emergency-bridge',
    'single_writer',
    'active',
    'fail_closed',
    'Status, heartbeat, policy check, route resolution, and queue status only.'
  ),
  (
    'credential_configuration',
    'supabase_edge_function',
    'canonical-client-config',
    'single_writer',
    'active',
    'fail_closed',
    'Returns client-safe canonical configuration only.'
  ),
  (
    'credential_readiness',
    'supabase_edge_function',
    'credential-readiness',
    'single_writer',
    'active',
    'fail_closed',
    'Presence booleans only; no values or derivatives.'
  ),
  (
    'command_queue',
    'supabase_edge_function',
    'pi-work-queue',
    'single_writer',
    'active',
    'fail_closed',
    'Bounded queue claim, complete, and fail owner.'
  ),
  (
    'telegram_poller',
    'openclaw_gateway',
    'existing OpenClaw Telegram connector',
    'single_writer',
    'pending',
    'reject_duplicate_owner',
    'No second bot poller or webhook owner may be created.'
  ),
  (
    'model_routing',
    'supabase_database',
    'bridge_resolve_route',
    'authoritative',
    'active',
    'fail_closed',
    'Zero-cost-first route decision; paid fallback disabled.'
  ),
  (
    'pi_execution',
    'raspberry_pi',
    'Raspberry Pi 5 OpenClaw worker',
    'pending',
    'pending',
    'fail_closed',
    'Requires authenticated heartbeat and command receipt.'
  ),
  (
    'phone_runtime',
    'raspberry_pi',
    'USB-connected Android companion',
    'pending',
    'pending',
    'fail_closed',
    'Requires T3 phone-bridge evidence.'
  ),
  (
    'vercel_deployment',
    'disabled',
    'no selected Vercel project',
    'disabled',
    'blocked',
    'fail_closed',
    'Connector/team may be valid, but deployment remains disabled until exactly one project is visible and explicitly selected.'
  )
on conflict (domain) do update set
  owner_type = excluded.owner_type,
  owner_ref = excluded.owner_ref,
  mode = excluded.mode,
  status = excluded.status,
  conflict_policy = excluded.conflict_policy,
  notes = excluded.notes,
  updated_at = now();

insert into public.bridge_completion_gates(
  gate_key,
  scope,
  status,
  required_for_complete,
  evidence_ref,
  blocker_code,
  next_action,
  last_verified_at
) values
  (
    'cloud_schema',
    'supabase',
    'pass',
    true,
    'bridge_self_test v1.2',
    null,
    null,
    now()
  ),
  (
    'edge_functions_active',
    'supabase',
    'pass',
    true,
    'emergency-bridge v3; credential-readiness v4; canonical-client-config v2',
    null,
    null,
    now()
  ),
  (
    'safe_defaults',
    'supabase',
    'pass',
    true,
    'paid fallback OFF; shell OFF; external and phone writes OFF; single-poller invariant ON',
    null,
    null,
    now()
  ),
  (
    'credential_export_boundary',
    'supabase',
    'pass',
    true,
    'credential_export_allowed count=0',
    null,
    null,
    now()
  ),
  (
    'route_resolver',
    'supabase',
    'pass',
    true,
    'risk0 selects ollama; risk4 stops; paid OpenAI is not selected',
    null,
    null,
    now()
  ),
  (
    'supabase_canonical_config',
    'credentials',
    'pass',
    true,
    'modern publishable selected; server key remains Edge-only',
    null,
    null,
    now()
  ),
  (
    'vercel_project_selection',
    'vercel',
    'blocked',
    false,
    null,
    'NO_EXPLICIT_VISIBLE_PROJECT',
    'Recheck the connected team project list and explicitly select exactly one project before enabling deployment.',
    now()
  ),
  (
    'pi_authenticated_status',
    'physical_pi',
    'pending',
    true,
    null,
    'PI_JWT_E2E_REQUIRED',
    'Run the Pi status smoke test with the current short-lived pi-gateway-client JWT.',
    null
  ),
  (
    'pi_heartbeat',
    'physical_pi',
    'pending',
    true,
    null,
    'PI_HEARTBEAT_REQUIRED',
    'Install the Pi heartbeat timer and record one successful heartbeat.',
    null
  ),
  (
    'canonical_config_pi_e2e',
    'physical_pi',
    'pending',
    true,
    null,
    'CANONICAL_CONFIG_E2E_REQUIRED',
    'Fetch canonical-client-config from the Pi and verify that no server secret is returned.',
    null
  ),
  (
    'phone_t3',
    'physical_phone',
    'pending',
    true,
    null,
    'PHONE_T3_REQUIRED',
    'Run the secure phone bridge verifier and retain the redacted receipt.',
    null
  ),
  (
    'telegram_t4',
    'telegram',
    'pending',
    true,
    null,
    'TELEGRAM_T4_REQUIRED',
    'Send one correlation-tagged request through the existing OpenClaw bot and verify the same correlation ID in the response.',
    null
  ),
  (
    'rollback_verified',
    'recovery',
    'pending',
    true,
    null,
    'PHYSICAL_ROLLBACK_TEST_REQUIRED',
    'Perform and verify non-destructive rollback after T3 staging.',
    null
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

create or replace view public.bridge_completion_summary
with (security_invoker = true)
as
select
  count(*) filter (where required_for_complete) as required_gates,
  count(*) filter (
    where required_for_complete and status = 'pass'
  ) as passed_required_gates,
  count(*) filter (
    where required_for_complete and status <> 'pass'
  ) as remaining_required_gates,
  bool_and(
    case when required_for_complete then status = 'pass' else true end
  ) as complete,
  coalesce(
    jsonb_agg(
      jsonb_build_object(
        'gate_key', gate_key,
        'scope', scope,
        'status', status,
        'blocker_code', blocker_code,
        'next_action', next_action
      )
      order by scope, gate_key
    ) filter (
      where required_for_complete and status <> 'pass'
    ),
    '[]'::jsonb
  ) as blockers,
  now() as generated_at
from public.bridge_completion_gates;

revoke all on public.bridge_completion_summary
  from public, anon, authenticated;
grant select on public.bridge_completion_summary to service_role;

create or replace function public.bridge_mark_completion_gate(
  p_gate_key text,
  p_status text,
  p_evidence_ref text default null,
  p_blocker_code text default null,
  p_next_action text default null
)
returns public.bridge_completion_gates
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_row public.bridge_completion_gates;
begin
  if p_status not in (
    'pass','partial','pending','blocked','not_tested','fail'
  ) then
    raise exception 'invalid completion status';
  end if;

  update public.bridge_completion_gates
  set status = p_status,
      evidence_ref = p_evidence_ref,
      blocker_code = p_blocker_code,
      next_action = p_next_action,
      last_verified_at = now(),
      updated_at = now()
  where gate_key = p_gate_key
  returning * into v_row;

  if not found then
    raise exception 'unknown completion gate';
  end if;

  return v_row;
end;
$$;

revoke all on function public.bridge_mark_completion_gate(
  text,text,text,text,text
) from public, anon, authenticated;
grant execute on function public.bridge_mark_completion_gate(
  text,text,text,text,text
) to service_role;

create index if not exists bridge_completion_gates_status_idx
  on public.bridge_completion_gates(required_for_complete,status,scope);

create index if not exists bridge_owner_registry_status_idx
  on public.bridge_owner_registry(status,mode,domain);
