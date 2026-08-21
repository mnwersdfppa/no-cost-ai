create or replace function public.bridge_credential_selection_self_test()
returns jsonb
language plpgsql
security definer
set search_path=public,pg_catalog
as $$
declare
  v_supabase integer;
  v_vercel integer;
  v_unusable integer;
  v_duplicates integer;
  v_rls integer;
  v_unsafe_grants integer;
begin
  select count(*) into v_supabase
  from public.bridge_credential_aliases
  where lower(canonical_integration) like '%supabase%' and selected=true;

  select count(*) into v_vercel
  from public.bridge_credential_aliases
  where lower(canonical_integration) like '%vercel%' and selected=true;

  select count(*) into v_unusable
  from public.bridge_credential_aliases
  where selected=true
    and lower(coalesce(status,'')) in ('invalid','blocked','quarantined','revoked','expired');

  select count(*) into v_duplicates
  from (
    select canonical_integration
    from public.bridge_credential_aliases
    where selected=true
    group by canonical_integration
    having count(*)>1
  ) d;

  select count(*) into v_rls
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in ('bridge_credential_aliases','bridge_canonical_credentials')
    and c.relrowsecurity;

  select count(*) into v_unsafe_grants
  from information_schema.role_table_grants
  where table_schema='public'
    and table_name in ('bridge_credential_aliases','bridge_canonical_credentials')
    and grantee in ('anon','authenticated');

  return jsonb_build_object(
    'status',case
      when v_supabase=1 and v_vercel=1
       and v_unusable=0 and v_duplicates=0
       and v_rls=2 and v_unsafe_grants=0
      then 'pass' else 'fail' end,
    'supabase_selected',v_supabase,
    'vercel_selected',v_vercel,
    'unusable_selected',v_unusable,
    'duplicate_integrations',v_duplicates,
    'rls_tables',v_rls,
    'unsafe_anon_authenticated_grants',v_unsafe_grants,
    'secret_values_checked',false,
    'generated_at',now()
  );
end;
$$;

revoke all on function public.bridge_credential_selection_self_test()
  from public,anon,authenticated;
grant execute on function public.bridge_credential_selection_self_test()
  to postgres,service_role;
