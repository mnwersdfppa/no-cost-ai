-- Normalize the local free model as its own integration. Health is provided only
-- by the authenticated Raspberry Pi heartbeat; no credential value is required.

insert into public.bridge_credentials(
  integration,
  canonical_secret_name,
  storage_scope,
  configured,
  validation_status,
  validation_detail,
  required_scopes,
  read_only_default,
  runtime_presence
) values (
  'ollama',
  null,
  'pi_local_secret',
  true,
  'unverified',
  'Local unauthenticated loopback model service. Health is supplied only by the authenticated Pi heartbeat; it must never be exposed publicly.',
  array['local_loopback'],
  true,
  jsonb_build_object('pi_local_runtime',true,'credential_required',false)
) on conflict (integration) do update set
  storage_scope='pi_local_secret',
  configured=true,
  validation_detail=excluded.validation_detail,
  required_scopes=excluded.required_scopes,
  read_only_default=true,
  runtime_presence=coalesce(public.bridge_credentials.runtime_presence,'{}'::jsonb) || excluded.runtime_presence,
  updated_at=now();

update public.bridge_route_registry
set integration='ollama',
    notes='Local loopback model route. Health comes only from the authenticated Raspberry Pi heartbeat; public exposure is forbidden.',
    updated_at=now()
where route_key='ollama.local';
