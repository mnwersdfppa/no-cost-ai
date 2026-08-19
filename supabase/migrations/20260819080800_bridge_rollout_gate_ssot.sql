-- Single-source completion ledger for the Supabase-first emergency bridge.

create table if not exists public.bridge_rollout_gates (
  gate_key text primary key,
  component text not null,
  status text not null check (status in ('pass','pending','blocked','fail','not_applicable')),
  blocking_reason text,
  next_action text,
  evidence jsonb not null default '{}'::jsonb,
  evidence_source text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bridge_rollout_gates enable row level security;
revoke all on table public.bridge_rollout_gates from anon, authenticated;
grant select, insert, update, delete on table public.bridge_rollout_gates to service_role;

comment on table public.bridge_rollout_gates is
  'Single source of truth for emergency bridge completion gates. Evidence must be non-secret and claim only observed state.';

create index if not exists bridge_rollout_gates_status_idx
  on public.bridge_rollout_gates (status, component, updated_at desc);

drop trigger if exists bridge_rollout_gates_updated_at on public.bridge_rollout_gates;
create trigger bridge_rollout_gates_updated_at
before update on public.bridge_rollout_gates
for each row execute function private.set_updated_at();

insert into public.bridge_rollout_gates(
  gate_key,component,status,blocking_reason,next_action,evidence,evidence_source
) values
  ('supabase.control_plane','Supabase','pass',null,
   'Keep fail-closed controls and maintenance jobs enabled.',
   jsonb_build_object('project_id','dpllasnpfskyyyzebyal','paid_api_fallback',false,'public_shell_execution',false),
   'supabase_database'),
  ('supabase.self_test','Supabase','pending','Latest deployment receipt must be refreshed.',
   'Run public.bridge_self_test().','{}'::jsonb,'bridge_deployment_receipts'),
  ('supabase.edge_unauth_rejection','Supabase','pass',null,
   'Retain verify_jwt=true and Pi role enforcement.',
   jsonb_build_object('emergency_bridge_http',401,'credential_readiness_http',401,'canonical_client_config_http',401),
   'edge_function_logs'),
  ('credentials.non_export','Credentials','pending','Capability registry must be checked for exportable credentials.',
   'Run refresh_bridge_rollout_gates().','{}'::jsonb,'bridge_capability_registry'),
  ('credentials.supabase_canonical','Credentials','pass',null,
   'New clients use the canonical managed publishable key source; server secret stays inside Edge runtime.',
   jsonb_build_object('project_id','dpllasnpfskyyyzebyal','client_source','managed_default_publishable','server_secret_returned',false),
   'canonical_client_config'),
  ('vercel.connector_identity','Vercel','pass',null,
   'Continue using the connected Vercel connector as the management identity.',
   jsonb_build_object('team_id','team_sa2sEffAlVXK6b9lsweDm6QL','team_slug','mnwersdfppap-5454s-projects','raw_token_fallback',false),
   'vercel_connector'),
  ('vercel.project_visibility','Vercel','blocked','No Vercel project is currently visible through the canonical connector.',
   'Expose or explicitly select the intended Vercel project before deployment.',
   jsonb_build_object('deployments_enabled',false),
   'vercel_connector'),
  ('pi.authenticated_status','Raspberry Pi','pending','A current short-lived Pi JWT is required on the physical Pi.',
   'Run the Pi installer and authenticated status smoke test.',
   jsonb_build_object('service_role_on_pi',false),
   'physical_pi'),
  ('pi.heartbeat','Raspberry Pi','pending','No current physical Pi heartbeat has been observed.',
   'Install and start openclaw-emergency-heartbeat.timer on the Pi.',
   '{}'::jsonb,'bridge_nodes'),
  ('phone.t3','Android phone','pending','Physical Pi-phone-Codex bridge evidence is absent.',
   'Complete T3 on the real Pi and phone.',
   '{}'::jsonb,'physical_device'),
  ('telegram.t4','Telegram','pending','Existing-bot correlation-ID round trip is absent.',
   'Complete T4 through the existing sole Telegram poller.',
   jsonb_build_object('second_poller_created',false),
   'physical_telegram'),
  ('github.pr5_merge','GitHub','blocked','Physical Pi smoke evidence and remaining review/CI gates are required.',
   'Keep PR #5 Draft and unmerged until all required gates pass.',
   jsonb_build_object('pr_number',5,'draft',true,'merged',false),
   'github_pr')
on conflict (gate_key) do update set
  component=excluded.component,
  status=excluded.status,
  blocking_reason=excluded.blocking_reason,
  next_action=excluded.next_action,
  evidence=excluded.evidence,
  evidence_source=excluded.evidence_source,
  updated_at=now();

create or replace function public.refresh_bridge_rollout_gates()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_latest_receipt public.bridge_deployment_receipts;
  v_exportable integer := 0;
  v_pi_online boolean := false;
  v_open_backlog integer := 0;
  v_summary jsonb;
begin
  select * into v_latest_receipt
  from public.bridge_deployment_receipts
  order by receipt_id desc
  limit 1;

  update public.bridge_rollout_gates
  set status = case when v_latest_receipt.status='pass' then 'pass' else 'fail' end,
      blocking_reason = case when v_latest_receipt.status='pass' then null else 'Latest Supabase bridge self-test did not pass.' end,
      next_action = case when v_latest_receipt.status='pass' then 'Preserve the passing migration and runtime controls.' else 'Inspect the latest deployment receipt and repair the failed check.' end,
      evidence = jsonb_build_object(
        'release_name',v_latest_receipt.release_name,
        'status',v_latest_receipt.status,
        'receipt_id',v_latest_receipt.receipt_id,
        'secret_values_checked',false
      ),
      evidence_source='bridge_deployment_receipts',
      updated_at=now()
  where gate_key='supabase.self_test';

  select count(*) into v_exportable
  from public.bridge_capability_registry
  where credential_export_allowed=true;

  update public.bridge_rollout_gates
  set status = case when v_exportable=0 then 'pass' else 'fail' end,
      blocking_reason = case when v_exportable=0 then null else 'One or more connector credentials are marked exportable.' end,
      next_action = case when v_exportable=0 then 'Keep connector credentials in their owning runtime.' else 'Disable credential export on every capability.' end,
      evidence=jsonb_build_object('exportable_capabilities',v_exportable,'secret_values_checked',false),
      evidence_source='bridge_capability_registry',
      updated_at=now()
  where gate_key='credentials.non_export';

  select exists(
    select 1 from public.bridge_nodes
    where node_type='raspberry_pi'
      and status in ('online','degraded')
      and last_seen_at > now()-interval '10 minutes'
  ) into v_pi_online;

  update public.bridge_rollout_gates
  set status = case when v_pi_online then 'pass' else 'pending' end,
      blocking_reason = case when v_pi_online then null else 'No current physical Pi heartbeat has been observed.' end,
      next_action = case when v_pi_online then 'Keep the five-minute heartbeat active.' else 'Install and start the Pi heartbeat timer.' end,
      evidence=jsonb_build_object('recent_pi_heartbeat',v_pi_online),
      evidence_source='bridge_nodes',
      updated_at=now()
  where gate_key='pi.heartbeat';

  select count(*) into v_open_backlog
  from public.bridge_security_backlog
  where status='open';

  select jsonb_build_object(
    'pass',(select count(*) from public.bridge_rollout_gates where status='pass'),
    'pending',(select count(*) from public.bridge_rollout_gates where status='pending'),
    'blocked',(select count(*) from public.bridge_rollout_gates where status='blocked'),
    'fail',(select count(*) from public.bridge_rollout_gates where status='fail'),
    'open_security_backlog',v_open_backlog,
    'generated_at',now()
  ) into v_summary;

  return v_summary;
end;
$$;

revoke all on function public.refresh_bridge_rollout_gates()
  from public,anon,authenticated;
grant execute on function public.refresh_bridge_rollout_gates()
  to postgres,service_role;

create or replace view public.bridge_rollout_summary
with (security_invoker=true)
as
select
  count(*) filter(where status='pass') as passed_gates,
  count(*) filter(where status='pending') as pending_gates,
  count(*) filter(where status='blocked') as blocked_gates,
  count(*) filter(where status='fail') as failed_gates,
  jsonb_agg(
    jsonb_build_object(
      'gate_key',gate_key,
      'component',component,
      'status',status,
      'blocking_reason',blocking_reason,
      'next_action',next_action,
      'evidence',evidence,
      'evidence_source',evidence_source,
      'updated_at',updated_at
    ) order by component,gate_key
  ) as gates,
  now() as generated_at
from public.bridge_rollout_gates;

revoke all on public.bridge_rollout_summary from public,anon,authenticated;
grant select on public.bridge_rollout_summary to service_role;

select public.refresh_bridge_rollout_gates();
