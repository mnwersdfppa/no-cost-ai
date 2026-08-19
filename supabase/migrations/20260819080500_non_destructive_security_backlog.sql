-- Inventory broad legacy grants without changing unrelated application access.

create table if not exists public.bridge_security_backlog (
  item_key text primary key,
  category text not null,
  object_schema text,
  object_name text,
  affected_role text,
  privilege_type text,
  severity text not null check (severity in ('info','warning','high','critical')),
  status text not null default 'open' check (status in ('open','reviewed','accepted','resolved','blocked')),
  recommended_action text not null,
  destructive_change_required boolean not null default false,
  source text not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bridge_security_backlog enable row level security;
revoke all on table public.bridge_security_backlog from anon, authenticated;
grant select, insert, update, delete on table public.bridge_security_backlog to service_role;

create index if not exists bridge_security_backlog_status_idx
  on public.bridge_security_backlog (status, severity, category, last_seen_at desc);

comment on table public.bridge_security_backlog is
  'Non-destructive security review queue. It does not revoke legacy application grants automatically.';

create or replace function public.refresh_bridge_security_backlog()
returns jsonb
language plpgsql
security definer
set search_path = public, information_schema, pg_catalog
as $$
declare
  v_exposure_count integer;
  v_open_count integer;
begin
  update public.bridge_security_backlog
  set status = 'resolved',
      updated_at = now()
  where source = 'database_grant_inventory'
    and status = 'open';

  insert into public.bridge_security_backlog(
    item_key,category,object_schema,object_name,affected_role,privilege_type,
    severity,status,recommended_action,destructive_change_required,source,
    first_seen_at,last_seen_at,updated_at
  )
  select
    md5(concat_ws(':','graphql_role_exposure',table_schema,table_name,grantee,privilege_type)),
    'graphql_role_exposure',
    table_schema,
    table_name,
    grantee,
    privilege_type,
    case when grantee = 'anon' then 'high' else 'warning' end,
    'open',
    case
      when grantee = 'anon' then 'Confirm public access is required; otherwise revoke the specific privilege or replace it with scoped RLS policies.'
      else 'Confirm every signed-in account should discover the object; otherwise revoke the broad privilege or add scoped RLS policies.'
    end,
    true,
    'database_grant_inventory',
    now(),
    now(),
    now()
  from information_schema.role_table_grants
  where table_schema = 'public'
    and grantee in ('anon','authenticated')
    and privilege_type = 'SELECT'
    and table_name not like 'bridge_%'
  on conflict (item_key) do update set
    severity = excluded.severity,
    status = 'open',
    recommended_action = excluded.recommended_action,
    last_seen_at = now(),
    updated_at = now();

  get diagnostics v_exposure_count = row_count;

  insert into public.bridge_security_backlog(
    item_key,category,severity,status,recommended_action,
    destructive_change_required,source,last_seen_at
  ) values (
    'auth:leaked-password-protection',
    'auth_configuration',
    'warning',
    'open',
    'Enable leaked-password protection in Supabase Auth after confirming the expected login and password-reset behavior.',
    false,
    'supabase_security_advisor_2026-08-19',
    now()
  ) on conflict (item_key) do update set
    status = case when public.bridge_security_backlog.status = 'resolved' then 'resolved' else 'open' end,
    last_seen_at = now(),
    updated_at = now();

  select count(*) into v_open_count
  from public.bridge_security_backlog
  where status = 'open';

  return jsonb_build_object(
    'grant_exposures_refreshed', v_exposure_count,
    'open_backlog_items', v_open_count,
    'permissions_changed', false,
    'secret_values_checked', false,
    'generated_at', now()
  );
end;
$$;

revoke all on function public.refresh_bridge_security_backlog() from public, anon, authenticated;
grant execute on function public.refresh_bridge_security_backlog() to postgres, service_role;

drop trigger if exists bridge_security_backlog_updated_at on public.bridge_security_backlog;
create trigger bridge_security_backlog_updated_at
before update on public.bridge_security_backlog
for each row execute function private.set_updated_at();

create or replace view public.bridge_readiness_snapshot
with (security_invoker = true)
as
select
  (select count(*) from public.bridge_credentials where configured and validation_status = 'valid') as valid_credentials,
  (select count(*) from public.bridge_credentials where validation_status in ('invalid','blocked')) as blocked_credentials,
  (select count(*) from public.bridge_permission_policies where enabled) as enabled_policies,
  (select count(*) from public.bridge_route_registry where enabled and health_status = 'healthy') as healthy_routes,
  (select count(*) from public.bridge_nodes where last_seen_at > now() - interval '10 minutes') as online_nodes,
  (select count(*) from public.openclaw_work_queue where status = 'queued') as queued_tasks,
  (select count(*) from public.bridge_security_backlog where status = 'open') as open_security_backlog,
  (select enabled from public.bridge_controls where control_key = 'paid_api_fallback') as paid_api_fallback,
  (select enabled from public.bridge_controls where control_key = 'telegram_single_poller_enforced') as telegram_single_poller_enforced,
  now() as generated_at;

revoke all on public.bridge_readiness_snapshot from public, anon, authenticated;
grant select on public.bridge_readiness_snapshot to service_role;

create extension if not exists pg_cron with schema extensions;
select cron.unschedule(jobid)
from cron.job
where jobname = 'refresh-bridge-security-backlog';
select cron.schedule(
  'refresh-bridge-security-backlog',
  '23 3 * * *',
  $$select public.refresh_bridge_security_backlog();$$
);

select public.refresh_bridge_security_backlog();
