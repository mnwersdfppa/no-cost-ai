-- Defense-in-depth: direct anon/authenticated access to the emergency bridge
-- tables is explicitly denied. All access is through reviewed Edge Functions
-- using service-role scope after user-JWT validation.

do $$
declare
  v_table text;
  v_policy text;
begin
  foreach v_table in array array[
    'bridge_credentials',
    'bridge_credential_aliases',
    'bridge_controls',
    'bridge_permission_policies',
    'bridge_route_registry',
    'bridge_nodes',
    'bridge_events',
    'bridge_request_ledger',
    'bridge_deployment_receipts'
  ]
  loop
    if to_regclass('public.' || v_table) is not null then
      v_policy := v_table || '_deny_direct_clients';
      execute format('drop policy if exists %I on public.%I', v_policy, v_table);
      execute format(
        'create policy %I on public.%I for all to anon, authenticated using (false) with check (false)',
        v_policy,
        v_table
      );
    end if;
  end loop;
end;
$$;

comment on schema private is
  'Security-definer implementation details. Direct client access is forbidden.';
