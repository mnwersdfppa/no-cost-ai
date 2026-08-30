-- Low-risk performance fixes identified by the Supabase advisor.
-- Adds covering indexes for foreign keys and removes only duplicate indexes
-- introduced during later hardening. No table data or access policy changes.

create index if not exists cost_ledger_job_id_idx
  on cf_rpi.cost_ledger(job_id);

create index if not exists bridge_credential_aliases_canonical_integration_idx
  on public.bridge_credential_aliases(canonical_integration);

create index if not exists bridge_route_registry_integration_idx
  on public.bridge_route_registry(integration);

create index if not exists command_feedback_decision_intent_idx
  on public.command_feedback(decision_id,intent_id);

create index if not exists command_intents_policy_version_idx
  on public.command_intents(policy_version);

create index if not exists command_intents_requested_by_idx
  on public.command_intents(requested_by)
  where requested_by is not null;

-- Keep the original production constraint/index names and remove only the
-- identical later indexes.
drop index if exists public.token_gateway_usage_user_created_idx;
drop index if exists public.token_gateway_usage_execution_key_uidx;
