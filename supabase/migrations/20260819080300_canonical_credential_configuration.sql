-- Canonical Supabase/Vercel configuration.
-- Stores only public metadata, non-secret policy, and secret *references*.
-- Credential values never enter this table or source control.

create table if not exists public.bridge_canonical_config (
  config_key text primary key,
  config_value jsonb not null,
  sensitivity text not null default 'non_secret'
    check (sensitivity in ('public','non_secret','secret_reference')),
  enabled boolean not null default true,
  source text not null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bridge_canonical_config enable row level security;
revoke all on table public.bridge_canonical_config from anon, authenticated;
grant select,insert,update,delete on table public.bridge_canonical_config to service_role;

drop policy if exists bridge_canonical_config_deny_direct_clients
  on public.bridge_canonical_config;
create policy bridge_canonical_config_deny_direct_clients
  on public.bridge_canonical_config
  for all to anon, authenticated
  using (false) with check (false);

drop trigger if exists bridge_canonical_config_updated_at
  on public.bridge_canonical_config;
create trigger bridge_canonical_config_updated_at
  before update on public.bridge_canonical_config
  for each row execute function private.set_updated_at();

insert into public.bridge_canonical_config(
  config_key,config_value,sensitivity,enabled,source,notes
)
values
  ('supabase.project',
    jsonb_build_object(
      'project_ref','dpllasnpfskyyyzebyal',
      'url','https://dpllasnpfskyyyzebyal.supabase.co',
      'region','ap-southeast-1'
    ),
    'public',true,'supabase_management_api',
    'Canonical active healthy Supabase project.'),
  ('supabase.client_key',
    jsonb_build_object(
      'environment','SUPABASE_PUBLISHABLE_KEYS',
      'name','default',
      'type','modern_publishable',
      'legacy_anon_fallback',false
    ),
    'secret_reference',true,'supabase_platform_managed',
    'Resolved only inside Edge Functions; returned only to an authenticated Pi client.'),
  ('supabase.server_key',
    jsonb_build_object(
      'environment','SUPABASE_SECRET_KEYS',
      'name','default',
      'legacy_service_role_compatibility',true,
      'client_exposure',false
    ),
    'secret_reference',true,'supabase_platform_managed',
    'Server key remains inside trusted server/Edge runtime.'),
  ('vercel.management',
    jsonb_build_object(
      'identity','connected_connector',
      'team_id','team_sa2sEffAlVXK6b9lsweDm6QL',
      'team_slug','mnwersdfppap-5454s-projects',
      'raw_token_fallback',false,
      'selected_project',null,
      'deployment_enabled',false
    ),
    'non_secret',true,'vercel_connected_connector',
    'Connector session is canonical; no visible project is selected.'),
  ('model.zero_cost_route',
    jsonb_build_object(
      'routes',jsonb_build_array('ollama:qwen2.5:3b','openrouter:free','stop'),
      'paid_api_fallback',false
    ),
    'non_secret',true,'bridge_policy','No automatic paid fallback.'),
  ('telegram.ownership',
    jsonb_build_object(
      'single_poller',true,
      'owner','openclaw_gateway',
      'secondary_poller_allowed',false
    ),
    'non_secret',true,'bridge_policy',
    'Existing OpenClaw Telegram poller remains sole owner.')
on conflict (config_key) do update set
  config_value=excluded.config_value,
  sensitivity=excluded.sensitivity,
  enabled=excluded.enabled,
  source=excluded.source,
  notes=excluded.notes,
  updated_at=now();

insert into public.bridge_controls(
  control_key,enabled,fail_closed,reason,updated_by
)
values
  ('supabase_modern_publishable_key',true,true,
   'Use SUPABASE_PUBLISHABLE_KEYS.default as the single client key.','canonicalization'),
  ('supabase_legacy_anon_fallback',false,true,
   'Legacy anon key is compatibility-only and is not selected for new clients.','canonicalization'),
  ('vercel_connector_management',true,true,
   'Use the connected Vercel connector session as the canonical management identity.','canonicalization'),
  ('vercel_raw_token_fallback',false,true,
   'Invalid and unverified raw Vercel tokens are quarantined.','canonicalization')
on conflict (control_key) do update set
  enabled=excluded.enabled,
  fail_closed=excluded.fail_closed,
  reason=excluded.reason,
  updated_by=excluded.updated_by,
  updated_at=now();

comment on table public.bridge_canonical_config is
  'Single source of truth for non-secret configuration and secret references. Never stores credential values.';
