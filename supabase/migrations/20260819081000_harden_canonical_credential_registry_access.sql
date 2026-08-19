alter table public.bridge_credential_aliases enable row level security;
alter table public.bridge_canonical_credentials enable row level security;

revoke all on table public.bridge_credential_aliases from anon,authenticated;
revoke all on table public.bridge_canonical_credentials from anon,authenticated;

grant select,insert,update,delete on table public.bridge_credential_aliases to service_role;
grant select,insert,update,delete on table public.bridge_canonical_credentials to service_role;

comment on table public.bridge_credential_aliases is
  'Authoritative non-secret credential-source selection registry. Direct anon/authenticated access is forbidden.';
