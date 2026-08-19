-- Canonical and compatibility credential alias tables contain metadata only,
-- but they are internal control-plane state and must not be exposed directly.

alter table public.bridge_canonical_credentials enable row level security;
alter table public.bridge_credential_aliases enable row level security;

revoke all on table public.bridge_canonical_credentials from anon, authenticated;
revoke all on table public.bridge_credential_aliases from anon, authenticated;

grant select, insert, update, delete on table public.bridge_canonical_credentials to service_role;
grant select, insert, update, delete on table public.bridge_credential_aliases to service_role;

comment on table public.bridge_canonical_credentials is
  'Service-role-only canonical credential alias metadata. No secret values are stored.';
comment on table public.bridge_credential_aliases is
  'Service-role-only deprecated compatibility metadata. New reads use bridge_credential_alias_ssot.';
