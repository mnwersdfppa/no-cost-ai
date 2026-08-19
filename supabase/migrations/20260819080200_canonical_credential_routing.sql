-- Canonical Supabase/Vercel credential routing.
-- Stores names, sources and validation states only. No key values, prefixes,
-- hashes, lengths, Authorization headers or OAuth tokens are persisted.

create table if not exists public.bridge_credential_aliases (
  alias_key text primary key,
  canonical_integration text not null,
  source_scope text not null check (source_scope in (
    'platform_managed','supabase_edge_env','supabase_vault','pi_local_secret',
    'oauth_device','n8n_credential','connector_external','unknown'
  )),
  status text not null check (status in (
    'valid','invalid','pending','blocked','not_present','not_tested',
    'unverified','external_only','unknown'
  )),
  selected boolean not null default false,
  last_validated_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists bridge_credential_aliases_selected_uidx
  on public.bridge_credential_aliases(canonical_integration)
  where selected;

alter table public.bridge_credential_aliases enable row level security;
revoke all on table public.bridge_credential_aliases from anon, authenticated;
grant select,insert,update,delete on table public.bridge_credential_aliases to service_role;

drop policy if exists bridge_explicit_deny on public.bridge_credential_aliases;
create policy bridge_explicit_deny
  on public.bridge_credential_aliases
  for all to anon, authenticated
  using (false)
  with check (false);

insert into public.bridge_credentials(
  integration,canonical_secret_name,storage_scope,configured,
  validation_status,validation_detail,required_scopes,read_only_default,
  runtime_presence,last_validated_at
) values
  (
    'supabase_client',null,'platform_managed',true,'valid',
    'Canonical client configuration uses SUPABASE_PUBLISHABLE_KEYS.default. Legacy anon fallback is disabled.',
    array['client:publishable'],true,
    jsonb_build_object('platform_managed',true,'selected_key_name','default','selected_key_type','publishable'),
    now()
  ),
  (
    'vercel_connector',null,'connector_external',true,'external_only',
    'Connected Vercel connector session is the canonical management identity; it is not exported to Pi or Supabase.',
    array['team:read','project:read'],true,
    jsonb_build_object('connector_external',true,'team_id','team_sa2sEffAlVXK6b9lsweDm6QL'),
    now()
  ),
  (
    'vercel_webhook',null,'supabase_vault',true,'not_tested',
    'Stored webhook candidate is retained but remains unselected until signature and endpoint tests pass.',
    array['webhook:invoke'],true,
    jsonb_build_object('supabase_vault',true),
    null
  )
on conflict (integration) do update set
  canonical_secret_name=excluded.canonical_secret_name,
  storage_scope=excluded.storage_scope,
  configured=excluded.configured,
  validation_status=excluded.validation_status,
  validation_detail=excluded.validation_detail,
  required_scopes=excluded.required_scopes,
  read_only_default=excluded.read_only_default,
  runtime_presence=excluded.runtime_presence,
  last_validated_at=excluded.last_validated_at,
  updated_at=now();

insert into public.bridge_credential_aliases(
  alias_key,canonical_integration,source_scope,status,selected,last_validated_at,notes
) values
  ('supabase.publishable.default','supabase_client','platform_managed','valid',true,now(),'Modern publishable key selected for all new clients.'),
  ('supabase.anon.legacy','supabase_client','platform_managed','valid',false,now(),'Compatibility only. Automatic fallback disabled.'),
  ('supabase.secret.default','supabase_platform','platform_managed','valid',true,now(),'Modern server secret selected inside hosted Edge Functions only.'),
  ('supabase.service_role.legacy','supabase_platform','platform_managed','valid',false,now(),'Legacy compatibility inside Edge runtime only.'),
  ('vault.Supabase-api-key','supabase','supabase_vault','invalid',false,now(),'Quarantined after 401 validation failure.'),
  ('vercel.connector.team_sa2sEffAlVXK6b9lsweDm6QL','vercel_connector','connector_external','valid',true,now(),'Canonical connected Vercel team session.'),
  ('vault.Vercel-api-key','vercel','supabase_vault','invalid',false,now(),'Quarantined after invalidToken response.'),
  ('vault.vercel1124com-webhooks','vercel_webhook','supabase_vault','not_tested',false,null,'Retained but disabled until signed negative and positive tests pass.')
on conflict (alias_key) do update set
  canonical_integration=excluded.canonical_integration,
  source_scope=excluded.source_scope,
  status=excluded.status,
  selected=excluded.selected,
  last_validated_at=excluded.last_validated_at,
  notes=excluded.notes,
  updated_at=now();

insert into public.bridge_controls(control_key,enabled,fail_closed,reason,updated_by) values
  ('supabase_modern_publishable_key',true,true,'Use SUPABASE_PUBLISHABLE_KEYS.default as the single client key.','canonical-routing'),
  ('supabase_legacy_anon_fallback',false,true,'Legacy anon is compatibility-only and not selected for new clients.','canonical-routing'),
  ('vercel_connector_management',true,true,'Use the connected Vercel connector session as canonical management identity.','canonical-routing'),
  ('vercel_raw_token_fallback',false,true,'Invalid and unverified raw Vercel tokens are quarantined.','canonical-routing'),
  ('vercel_deployments',false,true,'No visible project has been selected and verified.','canonical-routing')
on conflict (control_key) do update set
  enabled=excluded.enabled,
  fail_closed=excluded.fail_closed,
  reason=excluded.reason,
  updated_by=excluded.updated_by,
  updated_at=now();

insert into public.bridge_route_registry(
  route_key,integration,route_type,endpoint_alias,endpoint_url,
  mode,priority,enabled,health_status,notes
) values (
  'supabase.canonical_client_config','supabase_platform','edge_function',
  'canonical-client-config',
  'https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/canonical-client-config',
  'read_only',5,true,'not_tested',
  'JWT-protected canonical client configuration. Returns a publishable client key only; never a server secret.'
)
on conflict (route_key) do update set
  integration=excluded.integration,
  route_type=excluded.route_type,
  endpoint_alias=excluded.endpoint_alias,
  endpoint_url=excluded.endpoint_url,
  mode=excluded.mode,
  priority=excluded.priority,
  enabled=excluded.enabled,
  notes=excluded.notes,
  updated_at=now();
