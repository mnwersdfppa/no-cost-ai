-- Make the intentional service-role-only design explicit to the database linter.

do $$
declare
  table_name text;
begin
  for table_name in
    select unnest(array[
      'bridge_credentials',
      'bridge_credential_aliases',
      'bridge_controls',
      'bridge_permission_policies',
      'bridge_route_registry',
      'bridge_nodes',
      'bridge_events',
      'bridge_request_ledger',
      'bridge_deployment_receipts'
    ])
  loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists bridge_explicit_deny on public.%I',table_name);
    execute format(
      'create policy bridge_explicit_deny on public.%I for all to anon, authenticated using (false) with check (false)',
      table_name
    );
    execute format('revoke all on table public.%I from anon, authenticated',table_name);
  end loop;
end;
$$;

comment on policy bridge_explicit_deny on public.bridge_credentials is
  'Intentional fail-closed policy. Access is available only through service-role Edge Functions.';
