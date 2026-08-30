-- Select the deterministic zero-cost route resolver as the model-gateway owner.
-- The provider-execution Edge Function stays deployed but remains unselected
-- until its source proves it invokes the fail-closed policy gate.

insert into public.bridge_runtime_components(
  component_key,platform,component_type,component_role,canonical,selected,
  lifecycle_status,verify_jwt_required,observed_version,replacement_component_key,
  notes,last_verified_at
) values (
  'db.bridge_resolve_route',
  'supabase',
  'database_function',
  'model_gateway',
  true,
  true,
  'active',
  false,
  1,
  null,
  'Canonical zero-cost-first model route selector. It chooses a route but never calls a provider or returns credentials.',
  now()
) on conflict(component_key) do update set
  platform=excluded.platform,
  component_type=excluded.component_type,
  component_role=excluded.component_role,
  canonical=true,
  selected=true,
  lifecycle_status='active',
  verify_jwt_required=false,
  observed_version=excluded.observed_version,
  replacement_component_key=null,
  notes=excluded.notes,
  last_verified_at=now(),
  updated_at=now();

update public.bridge_runtime_components
set canonical=false,
    selected=false,
    lifecycle_status='pending_audit',
    replacement_component_key='db.bridge_resolve_route',
    notes='Provider execution function remains deployed, but it is not the selected model-gateway owner until its source invokes the fail-closed policy gate and proves no automatic paid fallback.',
    last_verified_at=now(),
    updated_at=now()
where component_key='edge.token-gateway';

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
  v_model_owner text;
  v_unaudited_token_gateway_selected integer;
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

  select component_key into v_model_owner
  from public.bridge_runtime_components
  where selected=true and component_role='model_gateway';

  select count(*) into v_unaudited_token_gateway_selected
  from public.bridge_runtime_components
  where component_key='edge.token-gateway' and selected=true;

  v_status:=case when
    v_required_selected=6
    and v_deprecated_selected=0
    and v_nonactive_selected=0
    and v_unprotected_selected=0
    and v_deprecated_routed=0
    and v_model_owner='db.bridge_resolve_route'
    and v_unaudited_token_gateway_selected=0
  then 'pass' else 'fail' end;

  v_checks:=jsonb_build_object(
    'required_selected_roles',jsonb_build_object('expected',6,'actual',v_required_selected,'pass',v_required_selected=6),
    'deprecated_selected',jsonb_build_object('expected',0,'actual',v_deprecated_selected,'pass',v_deprecated_selected=0),
    'nonactive_selected',jsonb_build_object('expected',0,'actual',v_nonactive_selected,'pass',v_nonactive_selected=0),
    'selected_edge_without_jwt',jsonb_build_object('expected',0,'actual',v_unprotected_selected,'pass',v_unprotected_selected=0),
    'enabled_routes_to_deprecated_components',jsonb_build_object('expected',0,'actual',v_deprecated_routed,'pass',v_deprecated_routed=0),
    'selected_model_gateway',jsonb_build_object('expected','db.bridge_resolve_route','actual',v_model_owner,'pass',v_model_owner='db.bridge_resolve_route'),
    'unaudited_token_gateway_selected',jsonb_build_object('expected',0,'actual',v_unaudited_token_gateway_selected,'pass',v_unaudited_token_gateway_selected=0),
    'provider_called',false,
    'deployed_token_gateway_deleted',false
  );

  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values('supabase-bridge-component-selection-v2',v_status,v_checks);

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
    raise exception 'component selection v2 self-test failed: %',v_result;
  end if;
end;
$$;
