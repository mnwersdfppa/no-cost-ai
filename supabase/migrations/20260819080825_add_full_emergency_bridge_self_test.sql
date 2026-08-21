-- One service-role-only regression gate for cloud control-plane readiness.

create or replace function public.bridge_full_self_test()
returns jsonb
language plpgsql
security definer
set search_path=public,pg_catalog
as $$
declare
  v_bridge jsonb;
  v_selection jsonb;
  v_status text;
begin
  v_bridge := public.bridge_self_test();
  v_selection := public.bridge_credential_selection_self_test();
  v_status := case
    when v_bridge ->> 'status' = 'pass'
     and v_selection ->> 'status' = 'pass'
    then 'pass'
    else 'fail'
  end;

  insert into public.bridge_deployment_receipts(release_name,status,checks)
  values(
    'supabase-first-emergency-bridge-v1.4',
    v_status,
    jsonb_build_object(
      'bridge',v_bridge,
      'credential_selection',v_selection,
      'physical_pi_authenticated_smoke_test',false,
      'vercel_target_project_validated',false,
      'secrets_returned',false,
      'legacy_permissions_changed',false
    )
  );

  return jsonb_build_object(
    'status',v_status,
    'bridge',v_bridge,
    'credential_selection',v_selection,
    'generated_at',now()
  );
end;
$$;

revoke all on function public.bridge_full_self_test()
  from public,anon,authenticated;
grant execute on function public.bridge_full_self_test()
  to postgres,service_role;
