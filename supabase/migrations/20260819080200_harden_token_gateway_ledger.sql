-- Harden the existing token-gateway usage ledger without changing the active
-- Edge Function source. This migration is additive and conflict-minimizing.

alter table public.token_gateway_usage enable row level security;
revoke all on table public.token_gateway_usage from anon, authenticated;
grant select, insert, update, delete on table public.token_gateway_usage to service_role;

create unique index if not exists token_gateway_usage_execution_key_uidx
  on public.token_gateway_usage (execution_key);

create index if not exists token_gateway_usage_user_created_idx
  on public.token_gateway_usage (user_id, created_at desc);

create index if not exists token_gateway_usage_status_created_idx
  on public.token_gateway_usage (status, created_at desc);

create index if not exists token_gateway_usage_provider_model_idx
  on public.token_gateway_usage (provider, model, created_at desc);

create or replace view public.token_gateway_daily_usage
with (security_invoker = true)
as
select
  user_id,
  provider,
  model,
  operation,
  date_trunc('day', created_at) as usage_day,
  count(*) filter (where status = 'succeeded') as succeeded_requests,
  count(*) filter (where status = 'failed') as failed_requests,
  coalesce(sum(input_tokens) filter (where status = 'succeeded'), 0) as input_tokens,
  coalesce(sum(output_tokens) filter (where status = 'succeeded'), 0) as output_tokens,
  coalesce(sum(total_tokens) filter (where status = 'succeeded'), 0) as total_tokens
from public.token_gateway_usage
group by
  user_id,
  provider,
  model,
  operation,
  date_trunc('day', created_at);

revoke all on public.token_gateway_daily_usage from public, anon, authenticated;
grant select on public.token_gateway_daily_usage to service_role;

create or replace function public.token_gateway_policy_gate(
  p_user_id uuid,
  p_provider text,
  p_model text,
  p_operation text
)
returns table(
  allowed boolean,
  reason text,
  approval_required boolean,
  daily_tokens bigint
)
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  v_role text;
  v_paid_enabled boolean;
  v_external_writes boolean;
  v_daily bigint;
begin
  select raw_app_meta_data ->> 'role'
  into v_role
  from auth.users
  where id = p_user_id;

  if v_role <> 'pi-gateway-client' then
    return query select false, 'pi_identity_required', true, 0::bigint;
    return;
  end if;

  select enabled
  into v_paid_enabled
  from public.bridge_controls
  where control_key = 'paid_api_fallback';

  select enabled
  into v_external_writes
  from public.bridge_controls
  where control_key = 'external_write_actions';

  select coalesce(sum(total_tokens), 0)
  into v_daily
  from public.token_gateway_usage
  where user_id = p_user_id
    and created_at >= date_trunc('day', now())
    and status = 'succeeded';

  if lower(coalesce(p_provider, '')) = 'openai'
     and coalesce(v_paid_enabled, false) = false then
    return query select false, 'paid_api_fallback_disabled', true, v_daily;
    return;
  end if;

  if p_operation not in (
    'chat',
    'summarize',
    'extract',
    'classify',
    'plan',
    'code_light',
    'health'
  ) then
    return query select false, 'operation_not_allowlisted', true, v_daily;
    return;
  end if;

  if p_operation = 'code_light'
     and coalesce(v_external_writes, false) = false then
    return query select false, 'external_write_actions_disabled', true, v_daily;
    return;
  end if;

  if lower(coalesce(p_provider, '')) not in (
    'ollama',
    'openrouter_free',
    'phone_codex_oauth',
    'openai'
  ) then
    return query select false, 'provider_not_allowlisted', true, v_daily;
    return;
  end if;

  return query select true, 'policy_allowed', false, v_daily;
end;
$$;

revoke all on function public.token_gateway_policy_gate(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.token_gateway_policy_gate(uuid, text, text, text)
  to service_role;

comment on function public.token_gateway_policy_gate(uuid, text, text, text) is
  'Fail-closed policy gate for future token-gateway revisions. The active gateway source is intentionally unchanged by this migration.';
