begin;

insert into public.bridge_credentials(
  integration, canonical_secret_name, detected_aliases, storage_scope,
  configured, validation_status, validation_detail, required_scopes,
  read_only_default, last_validated_at, runtime_presence, updated_at
) values
(
  'opencode',
  'Opencode-api-key',
  array['Opencode-api-key']::text[],
  'supabase_edge_env',
  true,
  'valid',
  'Exact Supabase Edge secret alias validated against OpenCode Zen /v1/models. Sixty-two key-scoped models were visible; no secret value was stored or returned.',
  array[]::text[],
  true,
  now(),
  jsonb_build_object(
    'supabase_edge_env', true,
    'exact_alias', 'Opencode-api-key',
    'live_validation_status', 200,
    'model_count', 62,
    'free_models', jsonb_build_array(
      'big-pickle',
      'deepseek-v4-flash-free',
      'laguna-s-2.1-free',
      'mimo-v2.5-free',
      'nemotron-3-ultra-free'
    ),
    'values_exposed', false
  ),
  now()
),
(
  'tailscale',
  'Tailscale-fff-api-key',
  array['Tailscale-fff-api-key']::text[],
  'supabase_edge_env',
  true,
  'valid',
  'Exact Supabase Edge secret alias classified as a Tailscale node auth key. It is valid for tailscale up node enrollment, not for the Tailscale control API.',
  array[]::text[],
  true,
  now(),
  jsonb_build_object(
    'supabase_edge_env', true,
    'exact_alias', 'Tailscale-fff-api-key',
    'credential_class', 'node_auth_key',
    'control_api_usable', false,
    'node_enrollment_usable', true,
    'values_exposed', false
  ),
  now()
)
on conflict (integration) do update set
  canonical_secret_name = excluded.canonical_secret_name,
  detected_aliases = excluded.detected_aliases,
  storage_scope = excluded.storage_scope,
  configured = excluded.configured,
  validation_status = excluded.validation_status,
  validation_detail = excluded.validation_detail,
  required_scopes = excluded.required_scopes,
  read_only_default = excluded.read_only_default,
  last_validated_at = excluded.last_validated_at,
  runtime_presence = excluded.runtime_presence,
  updated_at = excluded.updated_at;

update public.bridge_credentials
set configured = false,
    validation_status = 'not_present',
    validation_detail = 'No OpenRouter inference key is present in the Supabase Edge runtime. Opencode-api-key is an OpenCode Zen key and must not be treated as OpenRouter.',
    runtime_presence = jsonb_build_object(
      'supabase_edge_env', false,
      'values_exposed', false
    ),
    updated_at = now()
where integration = 'openrouter';

insert into public.bridge_controls(
  control_key, enabled, fail_closed, reason, expires_at, updated_by, updated_at
) values
  (
    'opencode_zen_free_route', true, true,
    'Validated OpenCode Zen key with five currently available free catalog models.',
    'infinity', 'chatgpt-20260820', now()
  ),
  (
    'tailscale_node_enrollment', true, true,
    'Validated Tailscale node auth key may enroll only the Raspberry Pi recovery node.',
    'infinity', 'chatgpt-20260820', now()
  ),
  (
    'tailscale_control_plane', false, true,
    'The stored Tailscale credential is a node auth key, not an API access token or OAuth client.',
    'infinity', 'chatgpt-20260820', now()
  ),
  (
    'tailscale_ssh_recovery', false, true,
    'Enable only after the Pi successfully joins the tailnet and reports Tailscale SSH readiness.',
    'infinity', 'chatgpt-20260820', now()
  ),
  (
    'local_ollama_route', false, true,
    'Local Ollama remains disabled until an authenticated Pi heartbeat proves both Ollama and Gateway health.',
    'infinity', 'chatgpt-20260820', now()
  ),
  (
    'openrouter_free_route', false, true,
    'No validated OpenRouter inference key exists; do not reuse the OpenCode key as OpenRouter.',
    'infinity', 'chatgpt-20260820', now()
  )
on conflict (control_key) do update set
  enabled = excluded.enabled,
  fail_closed = excluded.fail_closed,
  reason = excluded.reason,
  expires_at = excluded.expires_at,
  updated_by = excluded.updated_by,
  updated_at = excluded.updated_at;

insert into public.bridge_route_registry(
  route_key, integration, route_type, endpoint_alias, endpoint_url, mode,
  priority, enabled, health_status, last_checked_at, notes,
  capability, min_risk_tier, max_risk_tier, requires_control_key, updated_at
) values
(
  'opencode.zen.free',
  'opencode',
  'http_api',
  'opencode-zen-free-catalog',
  'https://opencode.ai/zen/v1',
  'free_only',
  10,
  true,
  'healthy',
  now(),
  'Key-scoped catalog validated. Primary opencode/nemotron-3-ultra-free; distinct OpenCode free fallbacks only.',
  'model_chat',
  0,
  2,
  'opencode_zen_free_route',
  now()
),
(
  'tailscale.node_enrollment',
  'tailscale',
  'connector',
  'tailscale-cli-auth-key',
  null,
  'approval_only',
  10,
  true,
  'not_tested',
  now(),
  'Use only through tailscale up --auth-key on the Raspberry Pi. This is not a control API route.',
  'private_network_enrollment',
  0,
  2,
  'tailscale_node_enrollment',
  now()
)
on conflict (route_key) do update set
  integration = excluded.integration,
  route_type = excluded.route_type,
  endpoint_alias = excluded.endpoint_alias,
  endpoint_url = excluded.endpoint_url,
  mode = excluded.mode,
  priority = excluded.priority,
  enabled = excluded.enabled,
  health_status = excluded.health_status,
  last_checked_at = excluded.last_checked_at,
  notes = excluded.notes,
  capability = excluded.capability,
  min_risk_tier = excluded.min_risk_tier,
  max_risk_tier = excluded.max_risk_tier,
  requires_control_key = excluded.requires_control_key,
  updated_at = excluded.updated_at;

update public.bridge_route_registry
set enabled = false,
    health_status = 'blocked',
    notes = 'No validated OpenRouter key. The exact Opencode-api-key belongs to OpenCode Zen.',
    last_checked_at = now(),
    updated_at = now()
where route_key = 'openrouter.free';

update public.bridge_route_registry
set enabled = false,
    health_status = 'unknown',
    priority = 30,
    notes = 'Pending authenticated physical Pi heartbeat and local qwen2.5:3b smoke test.',
    last_checked_at = now(),
    updated_at = now()
where route_key = 'ollama.local';

insert into public.bridge_canonical_config(
  config_key, config_value, sensitivity, enabled, source, notes, updated_at
) values
(
  'model.zero_cost_route',
  jsonb_build_object(
    'primary', 'opencode/nemotron-3-ultra-free',
    'fallbacks', jsonb_build_array(
      'opencode/deepseek-v4-flash-free',
      'opencode/mimo-v2.5-free',
      'opencode/big-pickle',
      'opencode/laguna-s-2.1-free'
    ),
    'utility_model', 'opencode/mimo-v2.5-free',
    'local_ollama_after_health', 'ollama/qwen2.5:3b',
    'paid_api_fallback', false,
    'session_unpin_command', '/model default'
  ),
  'non_secret',
  true,
  'validated_opencode_catalog',
  'Replaces the unavailable OpenRouter Nemotron ref and removes same-model duplicate fallback.',
  now()
),
(
  'tailscale.pi_enrollment',
  jsonb_build_object(
    'credential_alias', 'Tailscale-fff-api-key',
    'credential_class', 'node_auth_key',
    'cli_action', 'tailscale up --auth-key (value supplied through authenticated Pi bootstrap)',
    'hostname', 'raspberry-pi5-openclaw',
    'enable_ssh_after_join', true,
    'funnel', false,
    'serve_after_verification', true
  ),
  'non_secret',
  true,
  'validated_exact_alias',
  'Node enrollment only. No Tailscale control API permission is claimed.',
  now()
)
on conflict (config_key) do update set
  config_value = excluded.config_value,
  sensitivity = excluded.sensitivity,
  enabled = excluded.enabled,
  source = excluded.source,
  notes = excluded.notes,
  updated_at = excluded.updated_at;

create or replace function public.bridge_resolve_route(
  p_user_id uuid,
  p_capability text,
  p_risk_tier smallint default 0
)
returns table(
  route_key text,
  integration text,
  endpoint_alias text,
  route_type text,
  mode text,
  health_status text,
  priority smallint,
  decision text
)
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  v_role text;
begin
  select raw_app_meta_data ->> 'role'
  into v_role
  from auth.users
  where id = p_user_id;

  if v_role <> 'pi-gateway-client' then
    return query select
      null::text, null::text, null::text, null::text,
      null::text, null::text, null::smallint,
      'pi_identity_required'::text;
    return;
  end if;

  if p_capability is null
     or length(p_capability) < 1
     or length(p_capability) > 80
     or p_risk_tier not between 0 and 4 then
    return query select
      null::text, null::text, null::text, null::text,
      null::text, null::text, null::smallint,
      'invalid_route_request'::text;
    return;
  end if;

  perform public.refresh_bridge_route_health();

  return query
  select
    r.route_key,
    r.integration,
    r.endpoint_alias,
    r.route_type,
    r.mode,
    r.health_status,
    r.priority,
    'route_selected'::text
  from public.bridge_route_registry r
  left join public.bridge_controls c
    on c.control_key = r.requires_control_key
  where r.capability = p_capability
    and r.enabled = true
    and p_risk_tier between r.min_risk_tier and r.max_risk_tier
    and coalesce(c.enabled, true) = true
    and r.health_status in ('healthy', 'degraded')
    and not (
      r.integration = 'openai'
      and coalesce((
        select enabled
        from public.bridge_controls
        where control_key = 'paid_api_fallback'
      ), false) = false
    )
  order by r.priority asc
  limit 1;

  if not found then
    return query select
      null::text, null::text, null::text, null::text,
      'disabled'::text, 'blocked'::text, null::smallint,
      'stop_no_eligible_route'::text;
  end if;
end;
$$;

revoke all on function public.bridge_resolve_route(uuid, text, smallint)
  from public, anon, authenticated;
grant execute on function public.bridge_resolve_route(uuid, text, smallint)
  to service_role;

insert into public.openclaw_work_queue(
  task_key, task_type, payload, priority, status,
  attempts, max_attempts, not_before, updated_at
) values
(
  'pi-auth-opencode-tailscale-recovery-v2',
  'pi_infrastructure_recovery',
  jsonb_build_object(
    'objective', 'Refresh Pi JWT, enroll Tailscale, activate validated OpenCode free models, remove unavailable model refs, and verify Telegram.',
    'credential_aliases', jsonb_build_array(
      'Opencode-api-key',
      'Tailscale-fff-api-key'
    ),
    'primary', 'opencode/nemotron-3-ultra-free',
    'fallbacks', jsonb_build_array(
      'opencode/deepseek-v4-flash-free',
      'opencode/mimo-v2.5-free',
      'opencode/big-pickle',
      'opencode/laguna-s-2.1-free'
    ),
    'session_reset', 'model_default_required',
    'tailscale_mode', 'node_auth_key_cli_enrollment',
    'single_telegram_poller', true,
    'paid_api_fallback', false,
    'secret_values_forbidden_in_evidence', true
  ),
  100,
  'queued',
  0,
  5,
  now(),
  now()
),
(
  'telegram-model-session-unpin-v1',
  'telegram_model_session_recovery',
  jsonb_build_object(
    'agent', 'telegram-frontdoor',
    'action', 'clear unavailable user model pin after validated default is installed',
    'command', '/model default',
    'require_existing_single_poller', true,
    'no_second_bot', true
  ),
  99,
  'queued',
  0,
  3,
  now(),
  now()
)
on conflict (task_key) do update set
  task_type = excluded.task_type,
  payload = excluded.payload,
  priority = excluded.priority,
  status = 'queued',
  attempts = 0,
  max_attempts = excluded.max_attempts,
  not_before = now(),
  lease_until = null,
  claimed_by = null,
  last_error = null,
  updated_at = now();

insert into public.bridge_events(
  event_type, node_name, correlation_id, severity, outcome, detail, created_at
) values (
  'opencode_tailscale_exact_aliases_activated',
  'cloud-control-plane',
  null,
  'info',
  'succeeded',
  jsonb_build_object(
    'opencode_alias', 'Opencode-api-key',
    'opencode_models_visible', 62,
    'opencode_free_models', jsonb_build_array(
      'big-pickle',
      'deepseek-v4-flash-free',
      'laguna-s-2.1-free',
      'mimo-v2.5-free',
      'nemotron-3-ultra-free'
    ),
    'tailscale_alias', 'Tailscale-fff-api-key',
    'tailscale_credential_class', 'node_auth_key',
    'openrouter_key_present', false,
    'unknown_local_route_selection_removed', true,
    'secret_values_included', false
  ),
  now()
);

commit;
