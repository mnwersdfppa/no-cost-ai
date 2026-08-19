-- Complete the non-secret route inventory and operation-level policy matrix.

insert into public.bridge_route_registry(
  route_key,integration,route_type,endpoint_alias,endpoint_url,mode,priority,
  enabled,health_status,last_checked_at,notes
) values
  ('supabase.canonical_client_config','supabase_platform','edge_function',
   'canonical-client-config',
   'https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/canonical-client-config',
   'read_only',5,true,'degraded',now(),
   'Unauthenticated 401 guard passed; authenticated Pi JWT smoke test pending.'),
  ('supabase.credential_readiness','supabase_platform','edge_function',
   'credential-readiness',
   'https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/credential-readiness',
   'read_only',8,true,'degraded',now(),
   'Boolean credential presence only; authenticated Pi JWT smoke test pending.'),
  ('supabase.token_gateway','supabase_platform','edge_function',
   'token-gateway',
   'https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/token-gateway',
   'approval_only',25,true,'degraded',now(),
   'JWT protected; paid provider fallback remains disabled by control policy.'),
  ('vercel.connector_management','vercel','connector',
   'vercel-connected-session',null,
   'read_only',35,true,'degraded',now(),
   'Connected team identity is valid; zero visible projects and no selected deployment target.')
on conflict (route_key) do update set
  integration=excluded.integration,
  route_type=excluded.route_type,
  endpoint_alias=excluded.endpoint_alias,
  endpoint_url=excluded.endpoint_url,
  mode=excluded.mode,
  priority=excluded.priority,
  enabled=excluded.enabled,
  health_status=excluded.health_status,
  last_checked_at=excluded.last_checked_at,
  notes=excluded.notes,
  updated_at=now();

insert into public.bridge_permission_policies(
  policy_key,integration,operation,risk_tier,enabled,approval_required,
  max_calls_per_hour,max_payload_bytes,notes
) values
  ('supabase.canonical_config','supabase_platform','canonical_config',0,true,false,120,8192,
   'Authenticated Pi may read canonical public client configuration.'),
  ('supabase.credential_readiness','supabase_platform','credential_readiness',0,true,false,30,8192,
   'Boolean presence only; never values, prefixes, hashes or lengths.'),
  ('supabase.token_gateway_health','supabase_platform','token_gateway_health',0,true,false,60,8192,
   'Read-only gateway status and policy visibility.'),
  ('vercel.connector_status','vercel','connector_status',0,true,false,60,8192,
   'Read-only connected team and project visibility.'),
  ('vercel.deploy','vercel','deploy',3,false,true,0,262144,
   'Disabled until one project is visible, selected and preview-tested.')
on conflict (integration,operation) do update set
  risk_tier=excluded.risk_tier,
  enabled=excluded.enabled,
  approval_required=excluded.approval_required,
  max_calls_per_hour=excluded.max_calls_per_hour,
  max_payload_bytes=excluded.max_payload_bytes,
  notes=excluded.notes,
  updated_at=now();

insert into public.bridge_controls(control_key,enabled,fail_closed,reason,updated_by)
values
  ('canonical_config_distribution',true,true,
   'JWT-protected canonical public client configuration is the single distribution path.',
   'completion-review'),
  ('canonical_config_refresh_timer',false,true,
   'Pi timer package is prepared but cannot be enabled without physical Pi access and a current short-lived JWT.',
   'completion-review'),
  ('vercel_project_deployment',false,true,
   'No visible and explicitly selected Vercel project exists in the connected management scope.',
   'completion-review'),
  ('credential_candidate_autofallback',false,true,
   'Invalid, unverified or legacy candidates never become automatic fallbacks.',
   'completion-review')
on conflict (control_key) do update set
  enabled=excluded.enabled,
  fail_closed=excluded.fail_closed,
  reason=excluded.reason,
  updated_by=excluded.updated_by,
  updated_at=now();

select public.bridge_record_event(
  'emergency_bridge_completion_review',null,null,'info','succeeded',
  jsonb_build_object(
    'route_inventory_completed',true,
    'canonical_distribution_enabled',true,
    'pi_timer_physically_enabled',false,
    'vercel_deployment_enabled',false,
    'credential_autofallback',false,
    'secret_values_touched',false
  )
);
