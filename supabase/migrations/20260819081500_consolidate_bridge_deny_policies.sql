-- Consolidate duplicate deny-only RLS policies on every internal bridge table.
-- Direct anon/authenticated access remains denied, while redundant permissive
-- policies are removed to avoid unnecessary per-query policy evaluation.

do $$
declare
  r record;
begin
  for r in
    select tablename
    from pg_tables
    where schemaname='public'
      and tablename like 'bridge_%'
    order by tablename
  loop
    execute format('alter table public.%I enable row level security', r.tablename);
    execute format('revoke all on table public.%I from anon, authenticated', r.tablename);

    execute format('drop policy if exists bridge_explicit_deny on public.%I', r.tablename);
    execute format('drop policy if exists explicit_service_only_deny on public.%I', r.tablename);
    execute format('drop policy if exists %I on public.%I', r.tablename || '_deny_direct_clients', r.tablename);
    execute format('drop policy if exists %I on public.%I', r.tablename || '_deny_anon_authenticated', r.tablename);
    execute format('drop policy if exists bridge_deny_anon_authenticated on public.%I', r.tablename);

    execute format(
      'create policy bridge_deny_anon_authenticated on public.%I as restrictive for all to anon, authenticated using (false) with check (false)',
      r.tablename
    );
  end loop;
end;
$$;
