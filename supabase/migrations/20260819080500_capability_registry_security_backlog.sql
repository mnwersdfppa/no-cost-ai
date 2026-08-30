-- Version the external capability registry and a non-secret security backlog.
-- This migration never stores connector credentials, tokens, key derivatives,
-- Authorization headers, prompt contents or private model reasoning.

create table if not exists public.bridge_capability_registry (
  capability_key text primary key,
  provider text not null,
  surface_type text not null,
  access_mode text not null,
  available boolean not null default false,
  validated boolean not null default false,
  default_enabled boolean not null default false,
  credential_export_allowed boolean not null default false,
  notes text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bridge_capability_registry enable row level security;
revoke all on table public.bridge_capability_registry from anon,authenticated;
grant select,insert,update,delete on table public.bridge_capability_registry to service_role;
drop policy if exists bridge_explicit_deny on public.bridge_capability_registry;
create policy bridge_explicit_deny
  on public.bridge_capability_registry
  for all to anon,authenticated
  using(false)
  with check(false);

insert into public.bridge_capability_registry(
  capability_key,provider,surface_type,access_mode,available,validated,
  default_enabled,credential_export_allowed,notes
) values
  ('butlerbrain.connector','ButlerBrain','connector','write_gated',true,false,false,false,'External memory connector only; not used as the Supabase control-plane source of truth.'),
  ('codex_security.skill','Codex Security','plugin_skill','another_product',true,false,false,false,'Installed security workflow skill; repository analysis remains a separate Codex workflow.'),
  ('github.connector','GitHub','connector','write_gated',true,true,true,false,'Repository and PR access is available through the connected external connector. Default bridge use is read-only; writes remain explicit.'),
  ('gmail.connector','Gmail','connector','write_gated',true,true,true,false,'Mail search/read is available externally. Secret extraction and automatic sending are not part of the bridge.'),
  ('insurance_gpt.connector','Insurance GPT','connector','write_gated',true,false,false,false,'Domain connector available but excluded from emergency automation until a concrete task is reviewed.'),
  ('linear.connector','Linear','connector','write_gated',true,true,true,false,'Issue reads and rollout comments are available through the connected external connector.'),
  ('notion.connector','Notion','connector','write_gated',true,false,false,false,'Connector surface is available; no bridge credential is copied into Supabase and no write route is enabled.'),
  ('nvidia.external','NVIDIA','unknown','disabled',false,false,false,false,'No validated NVIDIA credential or active emergency-bridge route is available in this runtime.'),
  ('openai_ads.skill','OpenAI Ads Conversions','plugin_skill','another_product',true,false,false,false,'Installed Codex-oriented instrumentation skill; disabled in emergency runtime.'),
  ('openai_developers.skill','OpenAI Developers','plugin_skill','another_product',true,false,false,false,'Installed skill works best in Codex; it is not an API credential and is not exported into the bridge.'),
  ('payload_checker.connector','Payload Completeness Checker','connector','read_only',true,false,false,false,'Validation helper only. It receives bounded non-secret schemas and payload metadata.'),
  ('superhuman.connector','Superhuman Mail','connector','write_gated',true,false,false,false,'External mail connector only; no credential export or automatic send route.'),
  ('vercel.connector','Vercel','connector','write_gated',true,false,false,false,'External connector exists, but project visibility/deployment ownership is not yet validated. Supabase Vault Vercel token remains invalid.')
on conflict(capability_key) do update set
  provider=excluded.provider,
  surface_type=excluded.surface_type,
  access_mode=excluded.access_mode,
  available=excluded.available,
  validated=excluded.validated,
  default_enabled=excluded.default_enabled,
  credential_export_allowed=excluded.credential_export_allowed,
  notes=excluded.notes,
  updated_at=now();

create table if not exists public.bridge_security_backlog (
  finding_key text primary key,
  source text not null,
  severity text not null check(severity in ('info','warning','error','critical')),
  category text not null,
  status text not null default 'open' check(status in ('open','accepted','blocked','fixed')),
  affected_surface text,
  title text not null,
  detail text not null,
  remediation text,
  evidence jsonb not null default '{}'::jsonb,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bridge_security_backlog enable row level security;
revoke all on table public.bridge_security_backlog from anon,authenticated;
grant select,insert,update,delete on table public.bridge_security_backlog to service_role;
drop policy if exists bridge_explicit_deny on public.bridge_security_backlog;
create policy bridge_explicit_deny
  on public.bridge_security_backlog
  for all to anon,authenticated
  using(false)
  with check(false);

create index if not exists bridge_security_backlog_status_idx
  on public.bridge_security_backlog(status,severity,last_seen_at desc);

create or replace function public.refresh_bridge_security_backlog()
returns void
language plpgsql
security definer
set search_path=public,information_schema,pg_catalog
as $$
declare
  v_legacy_exposure_count integer;
  v_recent_pi boolean;
  v_canonical_healthy boolean;
begin
  select count(distinct table_name) into v_legacy_exposure_count
  from information_schema.role_table_grants
  where table_schema='public'
    and grantee in ('anon','authenticated')
    and privilege_type='SELECT'
    and table_name not like 'bridge_%';

  select exists(
    select 1 from public.bridge_nodes
    where node_type='raspberry_pi'
      and status in ('online','degraded')
      and last_seen_at>now()-interval '15 minutes'
  ) into v_recent_pi;

  select exists(
    select 1 from public.bridge_route_registry
    where route_key='supabase.canonical_client_config'
      and enabled=true
      and health_status='healthy'
  ) into v_canonical_healthy;

  insert into public.bridge_security_backlog(
    finding_key,source,severity,category,status,affected_surface,title,
    detail,remediation,evidence,last_seen_at,updated_at
  ) values
    (
      'legacy_graphql_exposure_review','supabase_advisor','warning','authorization',
      case when v_legacy_exposure_count>0 then 'open' else 'fixed' end,
      'public_schema','Review legacy public-schema GraphQL exposure',
      'Older non-bridge objects still grant SELECT to anon or all authenticated users. They are not modified automatically because intended consumers are not yet mapped.',
      'Review each object, identify its intended users, then revoke broad grants or add scoped RLS policies in a separate compatibility-tested migration.',
      jsonb_build_object('exposed_object_count',v_legacy_exposure_count,'credential_values_checked',false),
      now(),now()
    ),
    (
      'auth_leaked_password_protection_manual','supabase_advisor','warning','authentication','open',
      'supabase_auth','Confirm leaked-password protection in Supabase Auth',
      'The database control plane cannot safely change this dashboard-level Auth setting through the available connector.',
      'Enable leaked-password protection in the Supabase Auth dashboard after confirming sign-in policy compatibility.',
      jsonb_build_object('manual_dashboard_action',true,'credential_values_checked',false),
      now(),now()
    ),
    (
      'vercel_project_visibility','vercel_connector','info','deployment','open',
      'vercel_team','Select a visible canonical Vercel project',
      'The connected Vercel team session is valid, but no project is currently visible to the connector. Deployments remain disabled.',
      'Make the intended project visible through the connected team, then explicitly select and verify it before enabling deployment.',
      jsonb_build_object('team_id','team_sa2sEffAlVXK6b9lsweDm6QL','visible_project_count',0,'raw_token_fallback',false),
      now(),now()
    ),
    (
      'pi_authenticated_smoke_test','emergency_bridge','warning','runtime_validation',
      case when v_recent_pi then 'fixed' else 'open' end,
      'raspberry_pi','Run authenticated Pi heartbeat and smoke test',
      case when v_recent_pi then 'A recent authenticated Raspberry Pi heartbeat is present.' else 'No recent authenticated Raspberry Pi heartbeat is recorded.' end,
      'Install the canonical-config agent with a current Pi session and run the redacted bridge smoke test.',
      jsonb_build_object('recent_pi_heartbeat',v_recent_pi,'credential_values_checked',false),
      now(),now()
    ),
    (
      'canonical_client_config_authenticated','canonical-client-config','warning','runtime_validation',
      case when v_canonical_healthy then 'fixed' else 'open' end,
      'supabase_edge_function','Verify canonical client configuration with the Pi identity',
      case when v_canonical_healthy then 'The route is marked healthy after authenticated validation.' else 'The route is deployed but has not completed an authenticated Pi validation.' end,
      'Call canonical-client-config with the Pi user JWT and retain a redacted PASS receipt.',
      jsonb_build_object('route_healthy',v_canonical_healthy,'credential_values_checked',false),
      now(),now()
    )
  on conflict(finding_key) do update set
    source=excluded.source,
    severity=excluded.severity,
    category=excluded.category,
    status=excluded.status,
    affected_surface=excluded.affected_surface,
    title=excluded.title,
    detail=excluded.detail,
    remediation=excluded.remediation,
    evidence=excluded.evidence,
    last_seen_at=excluded.last_seen_at,
    updated_at=excluded.updated_at;
end;
$$;

revoke all on function public.refresh_bridge_security_backlog()
  from public,anon,authenticated;
grant execute on function public.refresh_bridge_security_backlog()
  to postgres,service_role;

select public.refresh_bridge_security_backlog();

select cron.unschedule(jobid)
from cron.job
where jobname='refresh-bridge-security-backlog';

select cron.schedule(
  'refresh-bridge-security-backlog',
  '17 * * * *',
  $$select public.refresh_bridge_security_backlog();$$
);

create or replace function public.bridge_self_test()
returns jsonb
language plpgsql
security definer
set search_path=public,information_schema,pg_catalog
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
  v_status text;
  v_checks jsonb;
begin
  select count(*) into v_required_tables
  from information_schema.tables
  where table_schema='public'
    and table_name in (
      'bridge_credentials','bridge_controls','bridge_permission_policies',
      'bridge_route_registry','bridge_nodes','bridge_events',
      'bridge_request_ledger','bridge_deployment_receipts',
      'bridge_capability_registry','bridge_security_backlog'
    );

  select count(*) into v_rls_tables
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in (
      'bridge_credentials','bridge_controls','bridge_permission_policies',
      'bridge_route_registry','bridge_nodes','bridge_events',
      'bridge_request_ledger','bridge_deployment_receipts',
      'bridge_capability_registry','bridge_security_backlog'
    )
    and c.relrowsecurity;

  select count(*) into v_unsafe_grants
  from information_schema.role_table_grants
  where table_schema='public'
    and table_name like 'bridge_%'
    and grantee in ('anon','authenticated');

  select count(*) into v_safe_controls
  from public.bridge_controls
  where (control_key='paid_api_fallback' and enabled=false)
     or (control_key='external_write_actions' and enabled=false)
     or (control_key='phone_write_actions' and enabled=false)
     or (control_key='public_shell_execution' and enabled=false)
     or (control_key='telegram_single_poller_enforced' and enabled=true)
     or (control_key='supabase_control_plane' and enabled=true);

  select count(*) into v_required_policies
  from public.bridge_permission_policies
  where (integration='supabase_platform'
         and operation in ('status','heartbeat','policy_check','queue_status','credential_readiness')
         and enabled=true)
     or (integration='openai' and operation='chat' and enabled=false);

  select exists(
    select 1 from cron.job
    where jobname='maintain-emergency-bridge' and active=true
  ) into v_maintenance_cron;

  select exists(
    select 1 from cron.job
    where jobname='refresh-bridge-security-backlog' and active=true
  ) into v_security_backlog_cron;

  select count(*) into v_unsafe_function_grants
  from information_schema.routine_privileges
  where specific_schema='public'
    and routine_name in (
      'bridge_record_heartbeat','bridge_policy_decision','bridge_record_event',
      'bridge_admit_request','refresh_bridge_security_backlog'
    )
    and grantee in ('anon','authenticated')
    and privilege_type='EXECUTE';

  select count(*) into v_capability_count
  from public.bridge_capability_registry;

  select count(*) into v_exportable_capabilities
  from public.bridge_capability_registry
  where credential_export_allowed=true;

  v_status:=case when
    v_required_tables=10
    and v_rls_tables=10
    and v_unsafe_grants=0
    and v_safe_controls=6
    and v_required_policies=6
    and v_maintenance_cron
    and v_security_backlog_cron
    and v_unsafe_function_grants=0
    and v_capability_count>=13
    and v_exportable_capabilities=0
  then 'pass' else 'fail' end;

  v_checks:=jsonb_build_object(
    'required_tables',jsonb_build_object('expected',10,'actual',v_required_tables,'pass',v_required_tables=10),
    'rls_tables',jsonb_build_object('expected',10,'actual',v_rls_tables,'pass',v_rls_tables=10),
    'unsafe_anon_authenticated_grants',jsonb_build_object('expected',0,'actual',v_unsafe_grants,'pass',v_unsafe_grants=0),
    'safe_control_defaults',jsonb_build_object('expected',6,'actual',v_safe_controls,'pass',v_safe_controls=6),
    'required_policy_defaults',jsonb_build_object('expected',6,'actual',v_required_policies,'pass',v_required_policies=6),
    'maintenance_cron',jsonb_build_object('pass',v_maintenance_cron),
    'security_backlog_cron',jsonb_build_object('pass',v_security_backlog_cron),
    'unsafe_function_execute_grants',jsonb_build_object('expected',0,'actual',v_unsafe_function_grants,'pass',v_unsafe_function_grants=0),
    'capability_registry_entries',jsonb_build_object('minimum',13,'actual',v_capability_count,'pass',v_capability_count>=13),
    'credential_export_allowed',jsonb_build_object('expected',0,'actual',v_exportable_capabilities,'pass',v_exportable_capabilities=0),
    'secret_values_checked',false,
    'paid_provider_called',false,
    'legacy_permissions_changed',false
  );

  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values('supabase-first-emergency-bridge-v1.2',v_status,v_checks);

  return jsonb_build_object('status',v_status,'checks',v_checks,'generated_at',now());
end;
$$;

revoke all on function public.bridge_self_test()
  from public,anon,authenticated;
grant execute on function public.bridge_self_test()
  to postgres,service_role;
