-- Register connector/plugin capabilities without importing OAuth or API secrets.

create table if not exists public.bridge_capability_registry (
  capability_key text primary key,
  provider text not null,
  surface_type text not null check (surface_type in ('connector','plugin_skill','local_runtime','cloud_runtime','unknown')),
  access_mode text not null check (access_mode in ('read_only','write_gated','local_only','another_product','disabled')),
  available boolean not null default false,
  validated boolean not null default false,
  default_enabled boolean not null default false,
  credential_export_allowed boolean not null default false,
  notes text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bridge_capability_registry enable row level security;
revoke all on table public.bridge_capability_registry from anon, authenticated;
grant select, insert, update, delete on table public.bridge_capability_registry to service_role;

comment on table public.bridge_capability_registry is
  'Non-secret connector/plugin capability boundary. OAuth and connector credentials remain in their owning runtime.';

create index if not exists bridge_capability_registry_state_idx
  on public.bridge_capability_registry (available, validated, default_enabled, provider);

insert into public.bridge_capability_registry(
  capability_key,provider,surface_type,access_mode,available,validated,default_enabled,credential_export_allowed,notes
) values
  ('github.connector','GitHub','connector','write_gated',true,true,true,false,
    'Repository and PR access is available through the connected external connector. Default bridge use is read-only; writes remain explicit.'),
  ('linear.connector','Linear','connector','write_gated',true,true,true,false,
    'Issue reads and rollout comments are available through the connected external connector.'),
  ('gmail.connector','Gmail','connector','write_gated',true,true,true,false,
    'Mail search/read is available externally. Secret extraction and automatic sending are not part of the bridge.'),
  ('vercel.connector','Vercel','connector','write_gated',true,false,false,false,
    'External connector exists, but project visibility/deployment ownership is not yet validated. Supabase Vault Vercel token remains invalid.'),
  ('notion.connector','Notion','connector','write_gated',true,false,false,false,
    'Connector surface is available; no bridge credential is copied into Supabase and no write route is enabled.'),
  ('superhuman.connector','Superhuman Mail','connector','write_gated',true,false,false,false,
    'External mail connector only; no credential export or automatic send route.'),
  ('butlerbrain.connector','ButlerBrain','connector','write_gated',true,false,false,false,
    'External memory connector only; not used as the Supabase control-plane source of truth.'),
  ('insurance_gpt.connector','Insurance GPT','connector','write_gated',true,false,false,false,
    'Domain connector available but excluded from emergency automation until a concrete task is reviewed.'),
  ('payload_checker.connector','Payload Completeness Checker','connector','read_only',true,false,false,false,
    'Validation helper only. It receives bounded non-secret schemas and payload metadata.'),
  ('openai_developers.skill','OpenAI Developers','plugin_skill','another_product',true,false,false,false,
    'Installed skill works best in Codex; it is not an API credential and is not exported into the bridge.'),
  ('openai_ads.skill','OpenAI Ads Conversions','plugin_skill','another_product',true,false,false,false,
    'Installed Codex-oriented instrumentation skill; disabled in emergency runtime.'),
  ('codex_security.skill','Codex Security','plugin_skill','another_product',true,false,false,false,
    'Installed security workflow skill; repository analysis remains a separate Codex workflow.'),
  ('nvidia.external','NVIDIA','unknown','disabled',false,false,false,false,
    'No validated NVIDIA credential or active emergency-bridge route is available in this runtime.')
on conflict (capability_key) do update set
  provider=excluded.provider,
  surface_type=excluded.surface_type,
  access_mode=excluded.access_mode,
  available=excluded.available,
  validated=excluded.validated,
  default_enabled=excluded.default_enabled,
  credential_export_allowed=false,
  notes=excluded.notes,
  updated_at=now();

drop trigger if exists bridge_capability_registry_updated_at on public.bridge_capability_registry;
create trigger bridge_capability_registry_updated_at
before update on public.bridge_capability_registry
for each row execute function private.set_updated_at();

insert into public.bridge_credentials(
  integration,canonical_secret_name,storage_scope,configured,validation_status,
  validation_detail,required_scopes,read_only_default,runtime_presence
) values
  ('vercel_connector',null,'connector_external',true,'external_only',
    'External Vercel connector exists; project/deployment visibility is not validated and the separate Vault token is invalid.',
    array['project:read'],true,jsonb_build_object('connector_external',true)),
  ('notion_connector',null,'connector_external',false,'not_tested',
    'Connector boundary registered; no credential export and no emergency write route.',
    array['content:read'],true,jsonb_build_object('connector_external',false)),
  ('superhuman_mail_connector',null,'connector_external',false,'not_tested',
    'Connector boundary registered; automatic mail send is disabled.',
    array['mail:read'],true,jsonb_build_object('connector_external',false)),
  ('butlerbrain_connector',null,'connector_external',false,'not_tested',
    'Connector boundary registered; Supabase remains the emergency SSOT.',
    array['memory:read'],true,jsonb_build_object('connector_external',false)),
  ('insurance_gpt_connector',null,'connector_external',false,'not_tested',
    'Connector boundary registered; no emergency action is enabled.',
    array['domain:read'],true,jsonb_build_object('connector_external',false)),
  ('payload_checker_connector',null,'connector_external',false,'not_tested',
    'Connector boundary registered for non-secret validation only.',
    array['validate'],true,jsonb_build_object('connector_external',false))
on conflict (integration) do update set
  storage_scope=excluded.storage_scope,
  configured=excluded.configured,
  validation_status=excluded.validation_status,
  validation_detail=excluded.validation_detail,
  required_scopes=excluded.required_scopes,
  read_only_default=true,
  runtime_presence=coalesce(public.bridge_credentials.runtime_presence,'{}'::jsonb) || excluded.runtime_presence,
  updated_at=now();

insert into public.bridge_permission_policies(
  policy_key,integration,operation,risk_tier,enabled,approval_required,max_calls_per_hour,max_payload_bytes,notes
) values
  ('vercel.connector_status','vercel_connector','status_read',1,false,true,30,16384,
    'Enable only after external connector project visibility is validated.'),
  ('notion.connector_read','notion_connector','content_read',1,false,true,30,32768,
    'Disabled until a concrete page/database scope is verified.'),
  ('superhuman.connector_read','superhuman_mail_connector','mail_read',1,false,true,30,32768,
    'Read-only after account connection verification; send remains excluded.'),
  ('butlerbrain.connector_read','butlerbrain_connector','memory_read',1,false,true,30,32768,
    'Read-only after connection verification; not the emergency SSOT.'),
  ('insurance.connector_read','insurance_gpt_connector','domain_read',1,false,true,20,32768,
    'Domain-specific read only after a reviewed use case.'),
  ('payload.connector_validate','payload_checker_connector','validate',0,false,true,60,65536,
    'Non-secret payload/schema validation only.')
on conflict (integration,operation) do update set
  risk_tier=excluded.risk_tier,
  enabled=false,
  approval_required=true,
  max_calls_per_hour=excluded.max_calls_per_hour,
  max_payload_bytes=excluded.max_payload_bytes,
  notes=excluded.notes,
  updated_at=now();
