-- Finalize non-secret credential source selection.
-- Values remain in Supabase-managed runtime secrets, device OAuth stores,
-- Pi-local 0600 files, n8n credential storage, or connected external sessions.

create or replace function private.validate_selected_credential_alias()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.selected and lower(coalesce(new.status,'')) in (
    'invalid','blocked','quarantined','revoked','expired'
  ) then
    raise exception 'cannot select unusable credential alias: %', new.alias_key;
  end if;
  return new;
end;
$$;

drop trigger if exists bridge_credential_aliases_validate_selection
  on public.bridge_credential_aliases;
create trigger bridge_credential_aliases_validate_selection
before insert or update of selected,status on public.bridge_credential_aliases
for each row execute function private.validate_selected_credential_alias();

create unique index if not exists bridge_credential_aliases_one_selected_per_integration
  on public.bridge_credential_aliases(canonical_integration)
  where selected=true;

create or replace view public.bridge_selected_credentials
with (security_invoker=true)
as
select
  a.canonical_integration,
  a.alias_key,
  a.source_scope,
  a.status,
  a.last_validated_at,
  a.notes,
  c.configured,
  c.validation_status,
  c.read_only_default,
  c.runtime_presence
from public.bridge_credential_aliases a
left join public.bridge_credentials c
  on c.integration=a.canonical_integration
where a.selected=true;

revoke all on public.bridge_selected_credentials from public,anon,authenticated;
grant select on public.bridge_selected_credentials to service_role;

insert into public.bridge_controls(control_key,enabled,fail_closed,reason,updated_by)
values(
  'credential_alias_registry_authoritative',true,true,
  'bridge_credential_aliases is the authoritative source-selection registry; bridge_credentials stores integration-level readiness only.',
  'migration'
)
on conflict(control_key) do update set
  enabled=true,
  fail_closed=true,
  reason=excluded.reason,
  updated_by='migration',
  updated_at=now();

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
begin
  select count(*) into v_supabase
  from public.bridge_credential_aliases
  where lower(canonical_integration) like '%supabase%'
    and selected=true;

  select count(*) into v_vercel
  from public.bridge_credential_aliases
  where lower(canonical_integration) like '%vercel%'
    and selected=true;

  select count(*) into v_unusable
  from public.bridge_credential_aliases
  where selected=true
    and lower(coalesce(status,'')) in (
      'invalid','blocked','quarantined','revoked','expired'
    );

  select count(*) into v_duplicates
  from (
    select canonical_integration
    from public.bridge_credential_aliases
    where selected=true
    group by canonical_integration
    having count(*)>1
  ) d;

  return jsonb_build_object(
    'status',case
      when v_supabase=1 and v_vercel=1
       and v_unusable=0 and v_duplicates=0
      then 'pass' else 'fail' end,
    'supabase_selected',v_supabase,
    'vercel_selected',v_vercel,
    'unusable_selected',v_unusable,
    'duplicate_integrations',v_duplicates,
    'secret_values_checked',false,
    'generated_at',now()
  );
end;
$$;

revoke all on function public.bridge_credential_selection_self_test()
  from public,anon,authenticated;
grant execute on function public.bridge_credential_selection_self_test()
  to postgres,service_role;
