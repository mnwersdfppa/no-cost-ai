-- Canonical component selector for the Supabase-first emergency bridge.
-- Legacy functions may remain deployed for compatibility, but they are not
-- selected or routed automatically.

create table if not exists public.bridge_runtime_components (
  component_key text primary key,
  platform text not null,
  component_type text not null check (component_type in ('edge_function','database_function','cron_job','local_service','external_connector','application')),
  component_role text not null,
  canonical boolean not null default false,
  selected boolean not null default false,
  lifecycle_status text not null check (lifecycle_status in ('active','compatibility','deprecated','pending_audit','disabled','unknown')),
  verify_jwt_required boolean not null default false,
  observed_version integer,
  replacement_component_key text,
  notes text not null,
  last_verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (not selected or canonical),
  check (not selected or lifecycle_status='active')
);

alter table public.bridge_runtime_components enable row level security;
revoke all on table public.bridge_runtime_components from anon,authenticated;
grant select,insert,update,delete on table public.bridge_runtime_components to service_role;

create unique index if not exists bridge_runtime_components_selected_role_uidx
  on public.bridge_runtime_components(platform,component_role)
  where selected=true;
create index if not exists bridge_runtime_components_lifecycle_idx
  on public.bridge_runtime_components(lifecycle_status,selected,platform,component_role);

insert into public.bridge_runtime_components(
  component_key,platform,component_type,component_role,canonical,selected,
  lifecycle_status,verify_jwt_required,observed_version,replacement_component_key,
  notes,last_verified_at
) values
  ('edge.emergency-bridge','supabase','edge_function','control_plane',true,true,'active',true,3,null,'Primary status, heartbeat, policy and zero-cost route-resolution endpoint.',now()),
  ('edge.credential-readiness','supabase','edge_function','credential_readiness',true,true,'active',true,4,null,'Presence booleans only; admission, idempotency and rate limits enforced.',now()),
  ('edge.canonical-client-config','supabase','edge_function','client_config',true,true,'active',true,2,null,'Returns canonical client-safe configuration only; no server secret.',now()),
  ('edge.pi-work-queue','supabase','edge_function','work_queue',true,true,'active',true,2,null,'Bounded Pi work queue endpoint.',now()),
  ('edge.token-gateway','supabase','edge_function','model_gateway',true,true,'active',true,66,null,'Existing provider gateway; source unchanged and paid fallback remains policy-gated.',now()),
  ('edge.pi-auth-bootstrap','supabase','edge_function','auth_bootstrap',true,true,'active',true,66,null,'Pi identity bootstrap; service-role and provider secrets remain server-side.',now()),
  ('edge.command-center','supabase','edge_function','decision_ingress',false,false,'pending_audit',true,1,null,'Active but not selected as the emergency control-plane owner until overlap is audited.',now()),
  ('edge.summarize-thread','supabase','application','application_summary',false,false,'compatibility',true,62,null,'Application function outside the emergency bridge selection.',now()),
  ('edge.secret-presence-probe','supabase','edge_function','legacy_credential_probe',false,false,'deprecated',true,4,'edge.credential-readiness','Superseded by credential-readiness; retained deployed but unselected.',now()),
  ('edge.secret-inventory-refresh','supabase','edge_function','legacy_credential_probe',false,false,'deprecated',true,2,'edge.credential-readiness','Superseded by credential-readiness and registry refresh.',now()),
  ('edge.integration-secret-presence-once','supabase','edge_function','legacy_credential_probe',false,false,'deprecated',true,2,'edge.credential-readiness','One-time probe superseded by credential-readiness.',now()),
  ('edge.overnight-absorber-probe','supabase','edge_function','legacy_validation_probe',false,false,'deprecated',true,3,'edge.emergency-bridge','Time-bounded probe superseded by deterministic bridge self-tests.',now()),
  ('edge.npm-metadata-probe','supabase','edge_function','legacy_package_probe',false,false,'deprecated',true,2,null,'Not part of the emergency bridge route.',now())
on conflict(component_key) do update set
  platform=excluded.platform,component_type=excluded.component_type,
  component_role=excluded.component_role,canonical=excluded.canonical,
  selected=excluded.selected,lifecycle_status=excluded.lifecycle_status,
  verify_jwt_required=excluded.verify_jwt_required,
  observed_version=excluded.observed_version,
  replacement_component_key=excluded.replacement_component_key,
  notes=excluded.notes,last_verified_at=excluded.last_verified_at,
  updated_at=now();

drop trigger if exists bridge_runtime_components_updated_at on public.bridge_runtime_components;
create trigger bridge_runtime_components_updated_at
before update on public.bridge_runtime_components
for each row execute function private.set_updated_at();

alter table public.bridge_route_registry
  add column if not exists component_key text references public.bridge_runtime_components(component_key) on update cascade on delete restrict;
update public.bridge_route_registry set component_key='edge.emergency-bridge' where route_key='supabase.emergency_bridge';
update public.bridge_route_registry set component_key='edge.credential-readiness' where route_key='supabase.credential_readiness';
update public.bridge_route_registry set component_key='edge.pi-work-queue' where route_key='supabase.pi_work_queue';
update public.bridge_route_registry set component_key='edge.token-gateway' where route_key='openai.paid_api';
create index if not exists bridge_route_registry_component_idx
  on public.bridge_route_registry(component_key) where component_key is not null;

create or replace view public.bridge_selected_components
with(security_invoker=true) as
select component_key,platform,component_type,component_role,lifecycle_status,
       verify_jwt_required,observed_version,last_verified_at,notes
from public.bridge_runtime_components
where selected=true
order by platform,component_role;
revoke all on public.bridge_selected_components from public,anon,authenticated;
grant select on public.bridge_selected_components to service_role;

create or replace function public.bridge_component_self_test()
returns jsonb
language plpgsql
security definer
set search_path=public,pg_catalog
as $$
declare
  v_required_selected integer;
  v_deprecated_selected integer;
  v_nonactive_selected integer;
  v_unprotected_selected integer;
  v_deprecated_routed integer;
  v_status text;
  v_checks jsonb;
begin
  select count(*) into v_required_selected
  from public.bridge_runtime_components
  where selected=true and component_role in (
    'control_plane','credential_readiness','client_config',
    'work_queue','model_gateway','auth_bootstrap'
  );
  select count(*) into v_deprecated_selected
  from public.bridge_runtime_components
  where selected=true and lifecycle_status='deprecated';
  select count(*) into v_nonactive_selected
  from public.bridge_runtime_components
  where selected=true and lifecycle_status<>'active';
  select count(*) into v_unprotected_selected
  from public.bridge_runtime_components
  where selected=true and component_type='edge_function' and verify_jwt_required=false;
  select count(*) into v_deprecated_routed
  from public.bridge_route_registry r
  join public.bridge_runtime_components c on c.component_key=r.component_key
  where r.enabled=true and c.lifecycle_status='deprecated';

  v_status:=case when
    v_required_selected=6 and v_deprecated_selected=0 and
    v_nonactive_selected=0 and v_unprotected_selected=0 and
    v_deprecated_routed=0
  then 'pass' else 'fail' end;

  v_checks:=jsonb_build_object(
    'required_selected_roles',jsonb_build_object('expected',6,'actual',v_required_selected,'pass',v_required_selected=6),
    'deprecated_selected',jsonb_build_object('expected',0,'actual',v_deprecated_selected,'pass',v_deprecated_selected=0),
    'nonactive_selected',jsonb_build_object('expected',0,'actual',v_nonactive_selected,'pass',v_nonactive_selected=0),
    'selected_edge_without_jwt',jsonb_build_object('expected',0,'actual',v_unprotected_selected,'pass',v_unprotected_selected=0),
    'enabled_routes_to_deprecated_components',jsonb_build_object('expected',0,'actual',v_deprecated_routed,'pass',v_deprecated_routed=0),
    'deployed_legacy_functions_deleted',false,
    'automatic_selection_conflicts_removed',true
  );

  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values('supabase-bridge-component-selection-v1',v_status,v_checks);
  return jsonb_build_object('status',v_status,'checks',v_checks,'generated_at',now());
end;
$$;
revoke all on function public.bridge_component_self_test() from public,anon,authenticated;
grant execute on function public.bridge_component_self_test() to postgres,service_role;

do $$
declare v_result jsonb;
begin
  v_result:=public.bridge_component_self_test();
  if v_result->>'status'<>'pass' then
    raise exception 'component selection self-test failed: %',v_result;
  end if;
end;
$$;
