-- Clarify intentional service-role-only access for internal telemetry tables.
-- Adding explicit deny policies preserves the existing effective access while
-- removing ambiguous RLS-without-policy state from the security advisor.

do $$
declare
  table_name text;
begin
  for table_name in
    select unnest(array[
      'bridge_capability_registry',
      'android_absorber_v3_runs',
      'bounded_runtime_final_summary',
      'fastpath_metrics',
      'openclaw_skill_registry'
    ])
  loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists explicit_service_only_deny on public.%I',table_name);
    execute format(
      'create policy explicit_service_only_deny on public.%I for all to anon, authenticated using(false) with check(false)',
      table_name
    );
    execute format('revoke all on table public.%I from anon, authenticated',table_name);
  end loop;
end;
$$;

comment on policy explicit_service_only_deny on public.bridge_capability_registry is
  'Intentional service-role-only registry. Connector credentials are never exportable.';
