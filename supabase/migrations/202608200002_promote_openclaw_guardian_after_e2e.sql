begin;

do $$
declare
  v_guardian_e2e_pass boolean;
  v_queue_e2e_pass boolean;
begin
  select exists (
    select 1
    from public.bridge_completion_gates
    where gate_key='pi_model_gateway_guardian_e2e'
      and status='pass'
      and evidence_ref is not null
  ) into v_guardian_e2e_pass;

  select exists (
    select 1
    from public.bridge_completion_gates
    where gate_key='pi_recovery_queue_api_e2e'
      and status='pass'
      and evidence_ref is not null
  ) into v_queue_e2e_pass;

  if v_guardian_e2e_pass and v_queue_e2e_pass then
    update public.bridge_runtime_components
    set canonical=false,
        selected=false,
        lifecycle_status='compatibility',
        replacement_component_key='edge.pi-model-gateway-guardian',
        notes='Compatibility rollback route retained after Guardian E2E promotion.',
        updated_at=now()
    where component_key='edge.pi-model-gateway';

    update public.bridge_runtime_components
    set selected=false,
        lifecycle_status='compatibility',
        replacement_component_key='edge.pi-model-gateway-guardian',
        notes='Compatibility-only provider gateway; direct OpenRouter fallback remains disabled.',
        updated_at=now()
    where component_key='edge.token-gateway';

    update public.bridge_runtime_components
    set canonical=true,
        selected=true,
        lifecycle_status='active',
        observed_version=greatest(observed_version,1),
        replacement_component_key=null,
        notes='Canonical scoped-Pi model gateway with per-model circuit breaker, at most two immediate attempts, durable retry queue and Telegram-safe synthetic acknowledgement.',
        last_verified_at=coalesce(last_verified_at,now()),
        updated_at=now()
    where component_key='edge.pi-model-gateway-guardian';

    insert into public.bridge_route_registry(
      route_key,
      integration,
      route_type,
      endpoint_alias,
      endpoint_url,
      mode,
      priority,
      enabled,
      health_status,
      last_checked_at,
      notes,
      capability,
      min_risk_tier,
      max_risk_tier,
      requires_control_key,
      component_key,
      created_at,
      updated_at
    ) values (
      'supabase.opencode_model_guardian',
      'opencode',
      'edge_function',
      'pi-model-gateway-guardian',
      'https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-model-gateway-guardian/v1',
      'free_only',
      1,
      true,
      'healthy',
      now(),
      'Canonical Pi Responses route; promotion requires Guardian and recovery-queue E2E evidence.',
      'model_chat',
      0,
      2,
      'opencode_zen_free_route',
      'edge.pi-model-gateway-guardian',
      now(),
      now()
    )
    on conflict (route_key) do update set
      integration=excluded.integration,
      route_type=excluded.route_type,
      endpoint_alias=excluded.endpoint_alias,
      endpoint_url=excluded.endpoint_url,
      mode=excluded.mode,
      priority=1,
      enabled=true,
      health_status='healthy',
      last_checked_at=now(),
      notes=excluded.notes,
      capability=excluded.capability,
      min_risk_tier=excluded.min_risk_tier,
      max_risk_tier=excluded.max_risk_tier,
      requires_control_key=excluded.requires_control_key,
      component_key=excluded.component_key,
      updated_at=now();

    update public.bridge_route_registry
    set priority=15,
        enabled=true,
        mode='compatibility',
        notes='Healthy rollback route retained; not selected as canonical after Guardian E2E.',
        last_checked_at=now(),
        updated_at=now()
    where route_key='supabase.opencode_model_gateway';

    update public.bridge_route_registry
    set enabled=false,
        mode='disabled',
        health_status='blocked',
        notes='Direct OpenRouter route disabled because no independently validated OpenRouter key is selected.',
        last_checked_at=now(),
        updated_at=now()
    where route_key='openrouter.free';

    update public.bridge_canonical_config
    set config_value=jsonb_set(
          config_value,
          '{base_url}',
          to_jsonb('https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-model-gateway-guardian/v1'::text),
          true
        ) || jsonb_build_object(
          'gateway_component','edge.pi-model-gateway-guardian',
          'queue_ack_on_total_failure',true,
          'max_immediate_provider_attempts',2,
          'paid_fallback',false,
          'single_telegram_poller',true,
          'provider_secret_location','supabase_edge_only'
        ),
        source='e2e-gated-guardian-promotion',
        notes='Guardian promotion is conditional on model-gateway and deterministic recovery-queue E2E evidence.',
        updated_at=now()
    where config_key='model.runtime_route';

    insert into public.bridge_events(
      event_type,
      node_name,
      correlation_id,
      severity,
      outcome,
      detail,
      created_at
    )
    select
      'pi_guardian_conditional_promotion_reconciled',
      'supabase',
      'migration-202608200002',
      'info',
      'succeeded',
      jsonb_build_object(
        'guardian_e2e_pass',true,
        'recovery_queue_e2e_pass',true,
        'canonical_component','edge.pi-model-gateway-guardian',
        'legacy_components_selected',false,
        'provider_secret_returned',false,
        'secret_values_included',false
      ),
      now()
    where not exists (
      select 1
      from public.bridge_events
      where event_type='pi_guardian_conditional_promotion_reconciled'
        and correlation_id='migration-202608200002'
    );
  else
    update public.bridge_runtime_components
    set canonical=false,
        selected=false,
        lifecycle_status='pending_audit',
        notes='Guardian source is present but promotion is blocked until model-gateway and recovery-queue E2E gates pass.',
        updated_at=now()
    where component_key='edge.pi-model-gateway-guardian'
      and not selected;
  end if;
end;
$$;

commit;
