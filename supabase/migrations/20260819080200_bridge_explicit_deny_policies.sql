-- Explicit deny policies for the emergency bridge control plane.
-- These policies document the fail-closed intent and silence RLS-without-policy
-- warnings. Edge Functions continue to use service_role, which bypasses RLS.

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
    if to_regclass(format('public.%I', v_table)) is null then
      continue;
    end if;
    v_policy := v_table || '_deny_anon_authenticated';
    execute format('drop policy if exists %I on public.%I', v_policy, v_table);
    execute format(
      'create policy %I on public.%I as restrictive for all to anon, authenticated using (false) with check (false)',
      v_policy,
      v_table
    );
    execute format('revoke all on table public.%I from anon, authenticated', v_table);
  end loop;
end;
$$;

comment on schema private is
  'Internal emergency-bridge functions. No anon or authenticated access.';
