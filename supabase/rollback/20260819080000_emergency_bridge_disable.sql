-- Non-destructive rollback for the Supabase emergency bridge.
-- Keeps evidence and schema for inspection. It disables all execution paths.

update public.bridge_controls
set enabled=false,
    reason=reason || ' [disabled by rollback]',
    updated_by='rollback',
    updated_at=now()
where control_key in (
  'emergency_bridge','supabase_control_plane','paid_api_fallback','external_write_actions',
  'phone_write_actions','public_shell_execution','maton_readonly','make_webhook',
  'n8n_queue_worker','vercel_deployments','phone_codex_route','openrouter_free_route',
  'local_ollama_route'
);

update public.bridge_route_registry
set enabled=false,
    mode='disabled',
    health_status='blocked',
    notes=coalesce(notes,'') || ' [disabled by rollback]',
    updated_at=now();

update public.bridge_permission_policies
set enabled=false,
    approval_required=true,
    updated_at=now();

select cron.unschedule(jobid)
from cron.job
where jobname='maintain-emergency-bridge';

select public.bridge_record_event(
  'emergency_bridge_rollback',null,null,'warning','succeeded',
  jsonb_build_object('destructive_drop',false,'schema_preserved',true,'secrets_touched',false)
);

-- Edge Functions are disabled separately by deploying a 410 fail-closed stub or
-- deleting them through the Supabase deployment control plane. No provider key
-- or Pi JWT is changed by this SQL rollback.
