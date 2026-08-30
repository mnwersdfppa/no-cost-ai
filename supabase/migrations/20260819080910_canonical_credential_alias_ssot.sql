-- Eliminate ambiguity between the canonical alias registry and its older
-- compatibility table without deleting historical metadata.

comment on table public.bridge_credential_aliases is
  'DEPRECATED compatibility table. Do not use for new reads or writes. Canonical alias selection is public.bridge_canonical_credentials.';

comment on table public.bridge_canonical_credentials is
  'Single source of truth for canonical Supabase/Vercel credential alias selection. Stores metadata only, never secret values.';

create or replace view public.bridge_credential_alias_ssot
with (security_invoker = true)
as
select
  alias_key,
  canonical_integration,
  source_scope,
  status,
  selected,
  configured,
  validation_status,
  read_only_default,
  last_validated_at,
  notes
from public.bridge_canonical_credentials;

revoke all on public.bridge_credential_alias_ssot from public, anon, authenticated;
grant select on public.bridge_credential_alias_ssot to service_role;

insert into public.bridge_controls(
  control_key,enabled,fail_closed,reason,updated_by
) values (
  'credential_alias_ssot',
  true,
  true,
  'New credential alias reads must use bridge_canonical_credentials or bridge_credential_alias_ssot; bridge_credential_aliases is compatibility-only.',
  'migration'
) on conflict (control_key) do update set
  enabled=true,
  fail_closed=true,
  reason=excluded.reason,
  updated_by='migration',
  updated_at=now();

insert into public.bridge_rollout_gates(
  gate_key,component,status,blocking_reason,next_action,evidence,evidence_source
) values (
  'credentials.alias_ssot',
  'Credentials',
  'pass',
  null,
  'Use bridge_credential_alias_ssot for all new alias-selection reads.',
  jsonb_build_object(
    'canonical_relation','bridge_canonical_credentials',
    'compatibility_relation','bridge_credential_aliases',
    'secret_values_stored',false
  ),
  'database_schema'
) on conflict (gate_key) do update set
  status='pass',
  blocking_reason=null,
  next_action=excluded.next_action,
  evidence=excluded.evidence,
  evidence_source=excluded.evidence_source,
  updated_at=now();

select public.refresh_bridge_rollout_gates();
