-- Final omission audit and additive hardening for the Supabase-first OpenClaw bridge.
-- Metadata only: no secret values, prefixes, lengths, hashes, JWTs, OAuth tokens,
-- refresh tokens, Authorization headers, or private keys are stored.

create table if not exists public.bridge_canonical_credentials (
  alias_key text primary key,
  canonical_integration text not null references public.bridge_credentials(integration) on update cascade on delete restrict,
  source_scope text not null,
  status text not null check (status in ('valid','compatibility','invalid','pending','external_only','not_tested','blocked')),
  selected boolean not null default false,
  configured boolean not null default false,
  validation_status text not null default 'unknown' check (validation_status in ('valid','invalid','pending','blocked','not_present','not_tested','unverified','external_only','unknown')),
  read_only_default boolean not null default true,
  last_validated_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bridge_canonical_credentials enable row level security;
revoke all on table public.bridge_canonical_credentials from anon, authenticated;
grant select,insert,update,delete on table public.bridge_canonical_credentials to service_role;

create unique index if not exists bridge_canonical_credentials_one_selected_uidx
  on public.bridge_canonical_credentials(canonical_integration)
  where selected=true;
create index if not exists bridge_canonical_credentials_status_idx
  on public.bridge_canonical_credentials(canonical_integration,selected,validation_status,status);

comment on table public.bridge_canonical_credentials is
  'Canonical credential alias SSOT. Metadata only; secret values and secret derivatives are forbidden.';

insert into public.bridge_credentials(
  integration,canonical_secret_name,storage_scope,configured,validation_status,
  validation_detail,required_scopes,read_only_default,runtime_presence
) values
  ('supabase_client','SUPABASE_PUBLISHABLE_KEYS.default','platform_managed',true,'valid',
   'Modern default publishable key is the canonical Pi/client key. Legacy anon automatic fallback is disabled.',
   array['client'],true,jsonb_build_object('platform_managed',true)),
  ('vercel_connector',null,'connector_external',true,'external_only',
   'Connected Vercel connector and canonical team are the management identity. Raw-token fallback and deployments remain disabled until a project is visible and selected.',
   array['team:read','project:read'],true,jsonb_build_object('connector_external',true))
on conflict (integration) do update set
  canonical_secret_name=excluded.canonical_secret_name,
  storage_scope=excluded.storage_scope,
  configured=excluded.configured,
  validation_status=excluded.validation_status,
  validation_detail=excluded.validation_detail,
  required_scopes=excluded.required_scopes,
  read_only_default=true,
  runtime_presence=coalesce(public.bridge_credentials.runtime_presence,'{}'::jsonb)||excluded.runtime_presence,
  updated_at=now();

do $$
begin
  if to_regclass('public.bridge_credential_aliases') is not null then
    insert into public.bridge_canonical_credentials(
      alias_key,canonical_integration,source_scope,status,selected,configured,
      validation_status,read_only_default,last_validated_at,notes
    )
    select
      a.alias_key,a.canonical_integration,a.source_scope,
      case when a.status in ('valid','compatibility','invalid','pending','external_only','not_tested')
           then a.status else 'not_tested' end,
      a.selected,coalesce(c.configured,false),coalesce(c.validation_status,'unknown'),
      coalesce(c.read_only_default,true),a.last_validated_at,a.notes
    from public.bridge_credential_aliases a
    left join public.bridge_credentials c on c.integration=a.canonical_integration
    on conflict (alias_key) do update set
      canonical_integration=excluded.canonical_integration,
      source_scope=excluded.source_scope,
      status=excluded.status,
      configured=excluded.configured,
      validation_status=excluded.validation_status,
      read_only_default=excluded.read_only_default,
      last_validated_at=excluded.last_validated_at,
      notes=excluded.notes,
      updated_at=now();
  end if;
end;
$$;

update public.bridge_canonical_credentials
set selected=false,updated_at=now()
where canonical_integration in ('supabase_client','supabase_platform','vercel_connector');

insert into public.bridge_canonical_credentials(
  alias_key,canonical_integration,source_scope,status,selected,configured,
  validation_status,read_only_default,last_validated_at,notes
) values
  ('supabase.publishable.default','supabase_client','platform_managed','valid',true,true,
   'valid',true,now(),'Canonical modern publishable key. Returned only to authenticated Pi/client callers.'),
  ('supabase.secret.default','supabase_platform','platform_managed','pending',true,true,
   'pending',false,null,'Canonical server-key target. Runtime class must be proven by authenticated function receipts before verification.'),
  ('vercel.connector.canonical_team','vercel_connector','connector_external','external_only',true,true,
   'external_only',true,now(),'Connected Vercel connector for the canonical team. Raw-token fallback and deployment remain disabled.')
on conflict (alias_key) do update set
  canonical_integration=excluded.canonical_integration,
  source_scope=excluded.source_scope,
  status=excluded.status,
  selected=excluded.selected,
  configured=excluded.configured,
  validation_status=excluded.validation_status,
  read_only_default=excluded.read_only_default,
  last_validated_at=excluded.last_validated_at,
  notes=excluded.notes,
  updated_at=now();

create or replace view public.bridge_credential_alias_ssot
with (security_invoker=true)
as
select alias_key,canonical_integration,source_scope,status,selected,configured,
       validation_status,read_only_default,last_validated_at,notes
from public.bridge_canonical_credentials;
revoke all on public.bridge_credential_alias_ssot from public,anon,authenticated;
grant select on public.bridge_credential_alias_ssot to service_role;

create table if not exists public.bridge_runtime_key_selection (
  function_name text primary key,
  selected_key_type text not null check (selected_key_type in (
    'modern_secret_default','modern_secret_named','legacy_service_role_compatibility','missing'
  )),
  modern_key_present boolean not null,
  legacy_key_present boolean not null,
  value_returned boolean not null default false,
  report_count bigint not null default 1 check (report_count>=1),
  first_reported_at timestamptz not null default now(),
  last_reported_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bridge_runtime_key_selection enable row level security;
revoke all on table public.bridge_runtime_key_selection from anon,authenticated;
grant select,insert,update,delete on table public.bridge_runtime_key_selection to service_role;
comment on table public.bridge_runtime_key_selection is
  'Runtime server-key class receipts only. Never stores key values, prefixes, hashes, lengths, tokens, or headers.';

insert into public.bridge_controls(control_key,enabled,fail_closed,reason,updated_by)
values
  ('credential_alias_ssot',true,true,'Canonical alias reads use bridge_credential_alias_ssot.','migration'),
  ('modern_server_key_unification_verified',false,true,'Requires fresh authenticated runtime receipts from all required Edge Functions.','migration')
on conflict (control_key) do update set
  enabled=case when excluded.control_key='credential_alias_ssot' then true else public.bridge_controls.enabled end,
  fail_closed=true,reason=excluded.reason,updated_by='migration',updated_at=now();

create or replace function public.bridge_record_runtime_key_selection(
  p_user_id uuid,p_function_name text,p_selected_key_type text,
  p_modern_key_present boolean,p_legacy_key_present boolean,
  p_value_returned boolean default false
)
returns boolean
language plpgsql security definer
set search_path=public,auth,pg_catalog
as $$
declare v_role text;
begin
  select raw_app_meta_data->>'role' into v_role from auth.users where id=p_user_id;
  if v_role<>'pi-gateway-client' then raise exception 'pi identity required'; end if;
  if p_function_name not in ('emergency-bridge','credential-readiness','canonical-client-config','command-center') then
    raise exception 'function not allowlisted';
  end if;
  if p_selected_key_type not in ('modern_secret_default','modern_secret_named','legacy_service_role_compatibility','missing') then
    raise exception 'invalid key class';
  end if;
  if p_value_returned then raise exception 'secret value return is forbidden'; end if;

  insert into public.bridge_runtime_key_selection(
    function_name,selected_key_type,modern_key_present,legacy_key_present,
    value_returned,report_count,first_reported_at,last_reported_at,updated_at
  ) values (
    p_function_name,p_selected_key_type,p_modern_key_present,p_legacy_key_present,
    false,1,now(),now(),now()
  )
  on conflict (function_name) do update set
    selected_key_type=excluded.selected_key_type,
    modern_key_present=excluded.modern_key_present,
    legacy_key_present=excluded.legacy_key_present,
    value_returned=false,
    report_count=public.bridge_runtime_key_selection.report_count+1,
    last_reported_at=now(),updated_at=now();
  return true;
end;
$$;
revoke all on function public.bridge_record_runtime_key_selection(uuid,text,text,boolean,boolean,boolean)
  from public,anon,authenticated;
grant execute on function public.bridge_record_runtime_key_selection(uuid,text,text,boolean,boolean,boolean)
  to service_role;

create or replace function public.bridge_reconcile_runtime_key_unification()
returns boolean
language plpgsql security definer
set search_path=public,pg_catalog
as $$
declare v_verified boolean;
begin
  select count(*)=4 into v_verified
  from public.bridge_runtime_key_selection
  where function_name in ('emergency-bridge','credential-readiness','canonical-client-config','command-center')
    and selected_key_type='modern_secret_default'
    and modern_key_present=true
    and value_returned=false
    and last_reported_at>=now()-interval '7 days';

  update public.bridge_controls
  set enabled=v_verified,
      reason=case when v_verified
        then 'All required Edge Functions reported modern_secret_default through authenticated runtime receipts.'
        else 'Waiting for fresh authenticated modern_secret_default receipts from all required Edge Functions.' end,
      updated_by='runtime-key-reconciler',updated_at=now()
  where control_key='modern_server_key_unification_verified';

  update public.bridge_canonical_credentials
  set status=case when v_verified then 'valid' else 'pending' end,
      validation_status=case when v_verified then 'valid' else 'pending' end,
      last_validated_at=case when v_verified then now() else last_validated_at end,
      updated_at=now()
  where alias_key='supabase.secret.default';
  return v_verified;
end;
$$;
revoke all on function public.bridge_reconcile_runtime_key_unification() from public,anon,authenticated;
grant execute on function public.bridge_reconcile_runtime_key_unification() to postgres,service_role;

do $$
declare r record;
begin
  for r in
    select conname from pg_constraint
    where conrelid='public.bridge_request_ledger'::regclass
      and contype='u'
      and replace(pg_get_constraintdef(oid),' ','')='UNIQUE(user_id,execution_key)'
  loop
    execute format('alter table public.bridge_request_ledger drop constraint %I',r.conname);
  end loop;
end;
$$;

drop index if exists public.bridge_request_ledger_user_id_execution_key_key;
create unique index if not exists bridge_request_ledger_user_action_execution_key_uidx
  on public.bridge_request_ledger(user_id,action,execution_key)
  where execution_key is not null;
create index if not exists bridge_request_ledger_action_rate_idx
  on public.bridge_request_ledger(user_id,action,created_at desc);

insert into public.bridge_permission_policies(
  policy_key,integration,operation,risk_tier,enabled,approval_required,
  max_calls_per_hour,max_payload_bytes,notes
) values
  ('supabase.canonical_config','supabase_platform','canonical_config',0,true,false,120,16384,'Read-only canonical client configuration.'),
  ('supabase.command_status','supabase_platform','command_status',0,true,false,120,65536,'Read-only command-center status.'),
  ('supabase.command_ingest','supabase_platform','command_ingest',1,true,false,240,131072,'Internal intent ingest; execution key required by Edge Function.'),
  ('supabase.decision_record','supabase_platform','decision_record',1,true,false,240,131072,'Internal decision receipt; execution key required.'),
  ('supabase.feedback_record','supabase_platform','feedback_record',1,true,false,240,131072,'Internal feedback receipt; execution key required.'),
  ('supabase.object_link','supabase_platform','object_link',1,true,false,240,131072,'Internal object link; execution key required.')
on conflict (integration,operation) do update set
  risk_tier=excluded.risk_tier,enabled=true,approval_required=false,
  max_calls_per_hour=excluded.max_calls_per_hour,
  max_payload_bytes=excluded.max_payload_bytes,notes=excluded.notes,updated_at=now();

create or replace function public.bridge_admit_request(
  p_user_id uuid,p_action text,p_execution_key text default null
)
returns table(allowed boolean,duplicate boolean,reason text,limit_per_hour integer,observed_last_hour bigint)
language plpgsql security definer
set search_path=public,auth,pg_catalog
as $$
declare
  v_role text; v_operation text; v_policy public.bridge_permission_policies;
  v_emergency_enabled boolean; v_existing public.bridge_request_ledger;
  v_count bigint; v_inserted integer; v_requires_key boolean;
begin
  select raw_app_meta_data->>'role' into v_role from auth.users where id=p_user_id;
  if v_role<>'pi-gateway-client' then return query select false,false,'pi_identity_required',0,0::bigint; return; end if;
  if p_action is null or length(p_action)<1 or length(p_action)>80 then return query select false,false,'invalid_action',0,0::bigint; return; end if;

  v_operation:=case p_action
    when 'status' then 'status' when 'heartbeat' then 'heartbeat'
    when 'policy_check' then 'policy_check' when 'queue_status' then 'queue_status'
    when 'credential_readiness' then 'credential_readiness' when 'resolve_route' then 'resolve_route'
    when 'canonical_config' then 'canonical_config' when 'command_status' then 'command_status'
    when 'command_ingest' then 'command_ingest' when 'decision_record' then 'decision_record'
    when 'feedback_record' then 'feedback_record' when 'object_link' then 'object_link'
    else null end;
  if v_operation is null then return query select false,false,'unsupported_action',0,0::bigint; return; end if;

  v_requires_key:=p_action in ('credential_readiness','command_ingest','decision_record','feedback_record','object_link');
  if v_requires_key and p_execution_key is null then return query select false,false,'execution_key_required',0,0::bigint; return; end if;
  if p_execution_key is not null and length(p_execution_key)>128 then return query select false,false,'execution_key_too_long',0,0::bigint; return; end if;

  select enabled into v_emergency_enabled from public.bridge_controls where control_key='emergency_bridge';
  if coalesce(v_emergency_enabled,false)=false then return query select false,false,'emergency_bridge_disabled',0,0::bigint; return; end if;

  if p_execution_key is not null then
    select * into v_existing from public.bridge_request_ledger
    where user_id=p_user_id and action=p_action and execution_key=p_execution_key;
    if found then return query select v_existing.allowed,true,'duplicate_execution_key',0,0::bigint; return; end if;
  end if;

  select * into v_policy from public.bridge_permission_policies
  where integration='supabase_platform' and operation=v_operation;
  if not found or v_policy.enabled=false then
    insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason)
    values(p_user_id,p_action,p_execution_key,false,'policy_disabled') on conflict do nothing;
    return query select false,false,'policy_disabled',0,0::bigint; return;
  end if;

  select count(*) into v_count from public.bridge_request_ledger
  where user_id=p_user_id and action=p_action and created_at>=now()-interval '1 hour';
  if v_policy.max_calls_per_hour=0 or v_count>=v_policy.max_calls_per_hour then
    insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason)
    values(p_user_id,p_action,p_execution_key,false,'rate_limit_exceeded') on conflict do nothing;
    return query select false,false,'rate_limit_exceeded',v_policy.max_calls_per_hour,v_count; return;
  end if;

  insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason)
  values(p_user_id,p_action,p_execution_key,true,'admitted') on conflict do nothing;
  get diagnostics v_inserted=row_count;
  if v_inserted=0 and p_execution_key is not null then
    select * into v_existing from public.bridge_request_ledger
    where user_id=p_user_id and action=p_action and execution_key=p_execution_key;
    return query select coalesce(v_existing.allowed,false),true,'duplicate_execution_key',v_policy.max_calls_per_hour,v_count; return;
  end if;
  return query select true,false,'admitted',v_policy.max_calls_per_hour,v_count;
end;
$$;
revoke all on function public.bridge_admit_request(uuid,text,text) from public,anon,authenticated;
grant execute on function public.bridge_admit_request(uuid,text,text) to service_role;

update public.bridge_route_registry
set capability='control_plane',requires_control_key='supabase_control_plane',enabled=true,updated_at=now()
where route_key in ('supabase.canonical_client_config','supabase.command_center');

create or replace function public.bridge_final_omission_self_test()
returns jsonb
language plpgsql security definer
set search_path=public,information_schema,pg_catalog
as $$
declare
  v_alias_ambiguity integer; v_action_coverage integer; v_direct_grants integer;
  v_exportable integer; v_safe_controls integer; v_runtime_verified boolean;
  v_status text; v_checks jsonb; v_definition text;
begin
  select count(*) into v_alias_ambiguity from (
    select canonical_integration from public.bridge_canonical_credentials
    where selected=true group by canonical_integration having count(*)>1
  ) q;
  v_definition:=pg_get_functiondef('public.bridge_admit_request(uuid,text,text)'::regprocedure);
  select count(*) into v_action_coverage
  from unnest(array['status','heartbeat','policy_check','queue_status','credential_readiness','resolve_route','canonical_config','command_status','command_ingest','decision_record','feedback_record','object_link']) a
  where position(quote_literal(a) in v_definition)>0;
  select count(*) into v_direct_grants from information_schema.role_table_grants
  where table_schema='public'
    and table_name in ('bridge_canonical_credentials','bridge_runtime_key_selection','bridge_credentials','bridge_controls','bridge_permission_policies','bridge_route_registry','bridge_nodes','bridge_events','bridge_request_ledger','bridge_deployment_receipts')
    and grantee in ('anon','authenticated');
  select count(*) into v_exportable from public.bridge_capability_registry where credential_export_allowed=true;
  select count(*) into v_safe_controls from public.bridge_controls
  where (control_key='paid_api_fallback' and enabled=false)
     or (control_key='external_write_actions' and enabled=false)
     or (control_key='phone_write_actions' and enabled=false)
     or (control_key='public_shell_execution' and enabled=false)
     or (control_key='telegram_single_poller_enforced' and enabled=true)
     or (control_key='vercel_raw_token_fallback' and enabled=false)
     or (control_key='vercel_deployments' and enabled=false)
     or (control_key='credential_alias_ssot' and enabled=true);
  select enabled into v_runtime_verified from public.bridge_controls where control_key='modern_server_key_unification_verified';
  v_status:=case when v_alias_ambiguity=0 and v_action_coverage=12 and v_direct_grants=0 and v_exportable=0 and v_safe_controls=8 then 'pass' else 'fail' end;
  v_checks:=jsonb_build_object(
    'canonical_alias_ambiguity',jsonb_build_object('expected',0,'actual',v_alias_ambiguity,'pass',v_alias_ambiguity=0),
    'admission_action_coverage',jsonb_build_object('expected',12,'actual',v_action_coverage,'pass',v_action_coverage=12),
    'unsafe_direct_grants',jsonb_build_object('expected',0,'actual',v_direct_grants,'pass',v_direct_grants=0),
    'credential_export_allowed',jsonb_build_object('expected',0,'actual',v_exportable,'pass',v_exportable=0),
    'safe_control_contracts',jsonb_build_object('expected',8,'actual',v_safe_controls,'pass',v_safe_controls=8),
    'modern_server_runtime_verified',coalesce(v_runtime_verified,false),
    'physical_pi_gate_pending',not coalesce(v_runtime_verified,false),
    'secret_values_checked',false,'secret_values_stored',false,'provider_called',false,'vercel_deployed',false
  );
  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values('supabase-first-emergency-bridge-omission-audit-v2',v_status,v_checks);
  return jsonb_build_object('status',v_status,'checks',v_checks,'generated_at',now());
end;
$$;
revoke all on function public.bridge_final_omission_self_test() from public,anon,authenticated;
grant execute on function public.bridge_final_omission_self_test() to postgres,service_role;

select public.bridge_reconcile_runtime_key_unification();
select public.bridge_final_omission_self_test();
