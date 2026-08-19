-- Supabase-first emergency bridge control plane
-- Applied to project dpllasnpfskyyyzebyal on 2026-08-19.
-- This schema stores credential references/status only. Secret values, prefixes,
-- hashes, lengths, Authorization headers and OAuth tokens are forbidden.

create schema if not exists private;

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function private.bridge_redact_jsonb(p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare
  v_type text;
begin
  if p_value is null then return '{}'::jsonb; end if;
  v_type := jsonb_typeof(p_value);
  if v_type = 'object' then
    return coalesce((
      select jsonb_object_agg(
        key,
        case
          when lower(key) ~ '(authorization|cookie|token|secret|password|api[_-]?key|oauth|jwt|private[_-]?key)'
            then to_jsonb('[REDACTED]'::text)
          else private.bridge_redact_jsonb(value)
        end
      )
      from jsonb_each(p_value)
    ), '{}'::jsonb);
  elsif v_type = 'array' then
    return coalesce((select jsonb_agg(private.bridge_redact_jsonb(value)) from jsonb_array_elements(p_value)), '[]'::jsonb);
  end if;
  return p_value;
end;
$$;

create table if not exists public.bridge_credentials (
  integration text primary key,
  canonical_secret_name text,
  detected_aliases text[] not null default '{}',
  storage_scope text not null default 'unknown' check (storage_scope in (
    'platform_managed','supabase_edge_env','supabase_vault','pi_local_secret','oauth_device',
    'n8n_credential','connector_external','unknown'
  )),
  configured boolean not null default false,
  validation_status text not null default 'unknown' check (validation_status in (
    'valid','invalid','pending','blocked','not_present','not_tested','unverified','external_only','unknown'
  )),
  validation_detail text,
  required_scopes text[] not null default '{}',
  read_only_default boolean not null default true,
  runtime_presence jsonb not null default '{}'::jsonb,
  last_validated_at timestamptz,
  rotation_due_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.bridge_controls (
  control_key text primary key,
  enabled boolean not null,
  fail_closed boolean not null default true,
  reason text not null,
  expires_at timestamptz,
  updated_by text not null default 'system',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.bridge_permission_policies (
  policy_key text primary key,
  integration text not null references public.bridge_credentials(integration) on update cascade on delete cascade,
  operation text not null,
  risk_tier smallint not null check (risk_tier between 0 and 4),
  enabled boolean not null default false,
  approval_required boolean not null default true,
  max_calls_per_hour integer not null default 0 check (max_calls_per_hour between 0 and 10000),
  max_payload_bytes integer not null default 16384 check (max_payload_bytes between 256 and 1048576),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (integration, operation)
);

create table if not exists public.bridge_route_registry (
  route_key text primary key,
  integration text not null references public.bridge_credentials(integration) on update cascade on delete cascade,
  route_type text not null check (route_type in ('edge_function','mcp','http_api','webhook','local_http','oauth_device','connector')),
  endpoint_alias text not null,
  endpoint_url text,
  mode text not null default 'read_only' check (mode in ('read_only','queue_only','free_only','approval_only','disabled')),
  priority smallint not null default 100 check (priority between 0 and 255),
  enabled boolean not null default false,
  health_status text not null default 'unknown' check (health_status in ('healthy','degraded','blocked','unknown','not_tested')),
  last_checked_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.bridge_nodes (
  node_id uuid primary key default gen_random_uuid(),
  node_name text not null unique,
  node_type text not null check (node_type in ('raspberry_pi','android_phone','desktop','cloud_worker','unknown')),
  auth_user_id uuid references auth.users(id) on delete set null,
  status text not null default 'unknown' check (status in ('online','offline','degraded','blocked','unknown')),
  capabilities jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.bridge_events (
  event_id bigint generated always as identity primary key,
  event_type text not null,
  node_name text,
  correlation_id text,
  severity text not null default 'info' check (severity in ('debug','info','warning','error','critical')),
  outcome text not null default 'observed' check (outcome in ('observed','allowed','denied','succeeded','failed','blocked')),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.bridge_request_ledger (
  request_id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null,
  execution_key text,
  allowed boolean not null,
  duplicate boolean not null default false,
  reason text not null,
  created_at timestamptz not null default now(),
  unique (user_id, execution_key)
);

create table if not exists public.bridge_deployment_receipts (
  receipt_id bigint generated always as identity primary key,
  release_name text not null,
  status text not null check (status in ('pass','partial','fail')),
  checks jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists bridge_credentials_validation_idx on public.bridge_credentials(validation_status,configured,integration);
create index if not exists bridge_permission_enabled_idx on public.bridge_permission_policies(integration,enabled,risk_tier);
create index if not exists bridge_routes_enabled_idx on public.bridge_route_registry(enabled,priority,health_status);
create index if not exists bridge_nodes_auth_user_idx on public.bridge_nodes(auth_user_id) where auth_user_id is not null;
create index if not exists bridge_nodes_last_seen_idx on public.bridge_nodes(last_seen_at desc nulls last);
create index if not exists bridge_events_created_idx on public.bridge_events(created_at desc);
create index if not exists bridge_events_correlation_idx on public.bridge_events(correlation_id) where correlation_id is not null;
create index if not exists bridge_request_ledger_rate_idx on public.bridge_request_ledger(user_id,action,created_at desc);

alter table public.bridge_credentials enable row level security;
alter table public.bridge_controls enable row level security;
alter table public.bridge_permission_policies enable row level security;
alter table public.bridge_route_registry enable row level security;
alter table public.bridge_nodes enable row level security;
alter table public.bridge_events enable row level security;
alter table public.bridge_request_ledger enable row level security;
alter table public.bridge_deployment_receipts enable row level security;

revoke all on table public.bridge_credentials,public.bridge_controls,public.bridge_permission_policies,
  public.bridge_route_registry,public.bridge_nodes,public.bridge_events,public.bridge_request_ledger,
  public.bridge_deployment_receipts from anon,authenticated;
grant select,insert,update,delete on table public.bridge_credentials,public.bridge_controls,
  public.bridge_permission_policies,public.bridge_route_registry,public.bridge_nodes,public.bridge_events,
  public.bridge_request_ledger to service_role;
grant select,insert on table public.bridge_deployment_receipts to service_role;
grant usage,select on sequence public.bridge_events_event_id_seq,public.bridge_request_ledger_request_id_seq,
  public.bridge_deployment_receipts_receipt_id_seq to service_role;

insert into public.bridge_credentials(
  integration,canonical_secret_name,storage_scope,configured,validation_status,validation_detail,required_scopes,read_only_default
) values
  ('supabase_platform','SUPABASE_SERVICE_ROLE_KEY','platform_managed',true,'valid','Platform-managed Edge runtime secret; never returned to Pi.',array['service_role'],false),
  ('openai','OPENAI_API_KEY','supabase_edge_env',false,'unknown','Paid fallback remains disabled even when configured.',array['responses:write'],true),
  ('openrouter','OPENROUTER_API_KEY','pi_local_secret',false,'unverified','Free-only route; no automatic paid routing.',array['free_models'],true),
  ('maton','MATON_API_KEY','oauth_device',false,'pending','Official remote MCP; read-only discovery tools first.',array['discovery:read'],true),
  ('make','MAKE_API_TOKEN','pi_local_secret',false,'pending','Signed, idempotent queue pulse only.',array['organization:read'],true),
  ('n8n','N8N_API_KEY','pi_local_secret',false,'pending','Inactive workflow import first.',array['workflow:read','workflow:create'],true),
  ('telegram','TELEGRAM_BOT_TOKEN','pi_local_secret',false,'unverified','Existing OpenClaw poller only.',array['bot'],true),
  ('notion','NOTION_API_KEY','pi_local_secret',false,'unverified','Read-only default.',array['read_content'],true),
  ('vercel','VERCEL_TOKEN','supabase_vault',true,'invalid','Previously validated as invalid; deploy route disabled.',array['project:read'],true),
  ('phone_codex_oauth',null,'oauth_device',false,'pending','Physical T3 verification pending.',array['chatgpt_subscription'],true),
  ('github_connector',null,'connector_external',true,'external_only','Connected ChatGPT connector only; not exported.',array['repo:read','pull_request:write'],true),
  ('linear_connector',null,'connector_external',true,'external_only','Rollout SSOT comments only.',array['issue:read','comment:write'],true),
  ('gmail_connector',null,'connector_external',true,'external_only','Mail metadata only; no secret extraction.',array['mail:read'],true)
on conflict (integration) do nothing;

insert into public.bridge_controls(control_key,enabled,fail_closed,reason,updated_by) values
  ('emergency_bridge',true,true,'Supabase emergency control plane enabled.','migration'),
  ('supabase_control_plane',true,true,'JWT-protected Supabase path is primary.','migration'),
  ('paid_api_fallback',false,true,'Explicit operator approval required.','migration'),
  ('external_write_actions',false,true,'Per-integration validation required.','migration'),
  ('phone_write_actions',false,true,'Physical verification and approval required.','migration'),
  ('public_shell_execution',false,true,'No shell through public endpoints.','migration'),
  ('telegram_single_poller_enforced',true,true,'Existing OpenClaw poller remains sole owner.','migration'),
  ('maton_readonly',false,true,'Authentication and tool probe required.','migration'),
  ('make_webhook',false,true,'Signed/idempotent negative tests required.','migration'),
  ('n8n_queue_worker',false,true,'Local credential binding and inactive import required.','migration'),
  ('vercel_deployments',false,true,'Credential replacement required.','migration'),
  ('phone_codex_route',false,true,'T3 and rollback evidence required.','migration'),
  ('openrouter_free_route',false,true,'Validated free-only credential required.','migration'),
  ('local_ollama_route',true,true,'Local route may be attempted and fail closed.','migration')
on conflict (control_key) do update set enabled=excluded.enabled,fail_closed=excluded.fail_closed,
  reason=excluded.reason,updated_by=excluded.updated_by,updated_at=now();

insert into public.bridge_permission_policies(
  policy_key,integration,operation,risk_tier,enabled,approval_required,max_calls_per_hour,max_payload_bytes,notes
) values
  ('supabase.status','supabase_platform','status',0,true,false,120,8192,'Read-only readiness snapshot.'),
  ('supabase.heartbeat','supabase_platform','heartbeat',0,true,false,240,32768,'Bounded redacted heartbeat.'),
  ('supabase.policy_check','supabase_platform','policy_check',0,true,false,240,8192,'Read-only decision.'),
  ('supabase.queue_status','supabase_platform','queue_status',0,true,false,120,8192,'Read-only queue status.'),
  ('openai.chat_paid','openai','chat',3,false,true,0,65536,'Automatic paid use disabled.'),
  ('phone_codex.chat','phone_codex_oauth','chat',2,false,true,30,65536,'Enable after T3.'),
  ('maton.discovery','maton','discovery',1,false,true,60,32768,'Read-only discovery.'),
  ('make.queue_pulse','make','queue_pulse',1,false,true,30,16384,'Signed/idempotent pulse.'),
  ('n8n.workflow_import','n8n','workflow_import_inactive',2,false,true,10,262144,'Inactive import only.'),
  ('vercel.status','vercel','status',1,false,true,30,16384,'Blocked until token replacement.'),
  ('github.pr_status','github_connector','pr_status_read',0,true,false,120,16384,'External connected read path.'),
  ('linear.rollout_comment','linear_connector','rollout_comment',1,true,false,60,32768,'SSOT comment only.'),
  ('gmail.credential_index','gmail_connector','credential_index_read',1,true,false,30,32768,'Metadata only.')
on conflict (integration,operation) do update set risk_tier=excluded.risk_tier,enabled=excluded.enabled,
  approval_required=excluded.approval_required,max_calls_per_hour=excluded.max_calls_per_hour,
  max_payload_bytes=excluded.max_payload_bytes,notes=excluded.notes,updated_at=now();

insert into public.bridge_route_registry(
  route_key,integration,route_type,endpoint_alias,endpoint_url,mode,priority,enabled,health_status,notes
) values
  ('supabase.emergency_bridge','supabase_platform','edge_function','emergency-bridge','https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/emergency-bridge','read_only',10,true,'not_tested','Primary emergency endpoint.'),
  ('supabase.pi_work_queue','supabase_platform','edge_function','pi-work-queue','https://dpllasnpfskyyyzebyal.supabase.co/functions/v1/pi-work-queue','queue_only',20,true,'unknown','Existing bounded queue.'),
  ('maton.remote_mcp','maton','mcp','maton-readonly','https://mcp.maton.ai','read_only',30,false,'not_tested','Write tools excluded.'),
  ('ollama.local','supabase_platform','local_http','ollama-qwen','http://127.0.0.1:11434','free_only',40,true,'unknown','Never publicly exposed.'),
  ('phone.codex_oauth','phone_codex_oauth','oauth_device','phone-codex-cli',null,'approval_only',50,false,'not_tested','OAuth remains on phone.'),
  ('openai.paid_api','openai','http_api','openai-paid','https://api.openai.com/v1','disabled',250,false,'blocked','No automatic paid fallback.')
on conflict (route_key) do update set mode=excluded.mode,priority=excluded.priority,enabled=excluded.enabled,
  health_status=excluded.health_status,notes=excluded.notes,updated_at=now();

create or replace function public.bridge_record_heartbeat(
  p_user_id uuid,p_node_name text,p_node_type text,p_status text,
  p_capabilities jsonb default '{}'::jsonb,p_metadata jsonb default '{}'::jsonb
)
returns public.bridge_nodes
language plpgsql security definer
set search_path=public,auth,private,pg_catalog
as $$
declare v_role text; v_row public.bridge_nodes;
begin
  select raw_app_meta_data->>'role' into v_role from auth.users where id=p_user_id;
  if v_role<>'pi-gateway-client' then raise exception 'pi identity required'; end if;
  if p_node_type not in ('raspberry_pi','android_phone','desktop','cloud_worker','unknown') then raise exception 'invalid node type'; end if;
  if p_status not in ('online','offline','degraded','blocked','unknown') then raise exception 'invalid status'; end if;
  if length(coalesce(p_node_name,'')) not between 1 and 100 then raise exception 'invalid node name'; end if;
  if pg_column_size(coalesce(p_capabilities,'{}'::jsonb))>32768 or pg_column_size(coalesce(p_metadata,'{}'::jsonb))>32768 then raise exception 'payload too large'; end if;
  insert into public.bridge_nodes(node_name,node_type,auth_user_id,status,capabilities,metadata,last_seen_at)
  values(p_node_name,p_node_type,p_user_id,p_status,private.bridge_redact_jsonb(p_capabilities),private.bridge_redact_jsonb(p_metadata),now())
  on conflict(node_name) do update set node_type=excluded.node_type,auth_user_id=excluded.auth_user_id,
    status=excluded.status,capabilities=excluded.capabilities,metadata=excluded.metadata,last_seen_at=excluded.last_seen_at,updated_at=now()
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.bridge_policy_decision(p_user_id uuid,p_integration text,p_operation text)
returns table(allowed boolean,approval_required boolean,risk_tier smallint,max_calls_per_hour integer,max_payload_bytes integer,reason text)
language plpgsql security definer
set search_path=public,auth,pg_catalog
as $$
declare v_role text; v_bridge boolean; v_paid boolean;
begin
  select raw_app_meta_data->>'role' into v_role from auth.users where id=p_user_id;
  if v_role<>'pi-gateway-client' then return query select false,true,4::smallint,0,0,'pi_identity_required'::text; return; end if;
  select enabled into v_bridge from public.bridge_controls where control_key='emergency_bridge';
  if coalesce(v_bridge,false)=false then return query select false,true,4::smallint,0,0,'emergency_bridge_disabled'::text; return; end if;
  select enabled into v_paid from public.bridge_controls where control_key='paid_api_fallback';
  return query select
    case when p.integration='openai' and p.operation='chat' and coalesce(v_paid,false)=false then false else p.enabled end,
    p.approval_required,p.risk_tier,p.max_calls_per_hour,p.max_payload_bytes,
    case when p.integration='openai' and p.operation='chat' and coalesce(v_paid,false)=false then 'paid_api_fallback_disabled'
         when p.enabled then 'policy_allowed' else 'policy_disabled' end
  from public.bridge_permission_policies p where p.integration=p_integration and p.operation=p_operation;
  if not found then return query select false,true,4::smallint,0,0,'policy_missing_fail_closed'::text; end if;
end;
$$;

create or replace function public.bridge_record_event(
  p_event_type text,p_node_name text default null,p_correlation_id text default null,
  p_severity text default 'info',p_outcome text default 'observed',p_detail jsonb default '{}'::jsonb
)
returns bigint
language plpgsql security definer
set search_path=public,private,pg_catalog
as $$
declare v_id bigint;
begin
  if length(coalesce(p_event_type,'')) not between 1 and 100 then raise exception 'invalid event type'; end if;
  if p_severity not in ('debug','info','warning','error','critical') then raise exception 'invalid severity'; end if;
  if p_outcome not in ('observed','allowed','denied','succeeded','failed','blocked') then raise exception 'invalid outcome'; end if;
  if pg_column_size(coalesce(p_detail,'{}'::jsonb))>65536 then raise exception 'detail too large'; end if;
  insert into public.bridge_events(event_type,node_name,correlation_id,severity,outcome,detail)
  values(p_event_type,p_node_name,p_correlation_id,p_severity,p_outcome,private.bridge_redact_jsonb(p_detail))
  returning event_id into v_id;
  return v_id;
end;
$$;

create or replace function public.bridge_admit_request(p_user_id uuid,p_action text,p_execution_key text default null)
returns table(allowed boolean,duplicate boolean,reason text,limit_per_hour integer,observed_last_hour bigint)
language plpgsql security definer
set search_path=public,auth,pg_catalog
as $$
declare v_role text; v_operation text; v_policy public.bridge_permission_policies; v_bridge boolean; v_existing public.bridge_request_ledger; v_count bigint;
begin
  select raw_app_meta_data->>'role' into v_role from auth.users where id=p_user_id;
  if v_role<>'pi-gateway-client' then return query select false,false,'pi_identity_required',0,0::bigint; return; end if;
  v_operation:=case p_action when 'status' then 'status' when 'heartbeat' then 'heartbeat' when 'policy_check' then 'policy_check' when 'queue_status' then 'queue_status' else null end;
  if v_operation is null then return query select false,false,'unsupported_action',0,0::bigint; return; end if;
  select enabled into v_bridge from public.bridge_controls where control_key='emergency_bridge';
  if coalesce(v_bridge,false)=false then return query select false,false,'emergency_bridge_disabled',0,0::bigint; return; end if;
  if p_execution_key is not null then
    if length(p_execution_key)>128 then return query select false,false,'execution_key_too_long',0,0::bigint; return; end if;
    select * into v_existing from public.bridge_request_ledger where user_id=p_user_id and execution_key=p_execution_key;
    if found then return query select v_existing.allowed,true,'duplicate_execution_key',0,0::bigint; return; end if;
  end if;
  select * into v_policy from public.bridge_permission_policies where integration='supabase_platform' and operation=v_operation;
  if not found or v_policy.enabled=false then
    insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason) values(p_user_id,p_action,p_execution_key,false,'policy_disabled');
    return query select false,false,'policy_disabled',0,0::bigint; return;
  end if;
  select count(*) into v_count from public.bridge_request_ledger where user_id=p_user_id and action=p_action and created_at>=now()-interval '1 hour';
  if v_policy.max_calls_per_hour=0 or v_count>=v_policy.max_calls_per_hour then
    insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason) values(p_user_id,p_action,p_execution_key,false,'rate_limit_exceeded');
    return query select false,false,'rate_limit_exceeded',v_policy.max_calls_per_hour,v_count; return;
  end if;
  insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason) values(p_user_id,p_action,p_execution_key,true,'admitted');
  return query select true,false,'admitted',v_policy.max_calls_per_hour,v_count;
end;
$$;

revoke all on function public.bridge_record_heartbeat(uuid,text,text,text,jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.bridge_policy_decision(uuid,text,text) from public,anon,authenticated;
revoke all on function public.bridge_record_event(text,text,text,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.bridge_admit_request(uuid,text,text) from public,anon,authenticated;
grant execute on function public.bridge_record_heartbeat(uuid,text,text,text,jsonb,jsonb),
  public.bridge_policy_decision(uuid,text,text),public.bridge_record_event(text,text,text,text,text,jsonb),
  public.bridge_admit_request(uuid,text,text) to service_role;

create or replace view public.bridge_readiness_snapshot with(security_invoker=true) as
select
  (select count(*) from public.bridge_credentials where configured and validation_status='valid') as valid_credentials,
  (select count(*) from public.bridge_credentials where validation_status in ('invalid','blocked')) as blocked_credentials,
  (select count(*) from public.bridge_permission_policies where enabled) as enabled_policies,
  (select count(*) from public.bridge_route_registry where enabled and health_status='healthy') as healthy_routes,
  (select count(*) from public.bridge_nodes where last_seen_at>now()-interval '10 minutes') as online_nodes,
  (select count(*) from public.openclaw_work_queue where status='queued') as queued_tasks,
  (select enabled from public.bridge_controls where control_key='paid_api_fallback') as paid_api_fallback,
  (select enabled from public.bridge_controls where control_key='telegram_single_poller_enforced') as telegram_single_poller_enforced,
  now() as generated_at;
revoke all on public.bridge_readiness_snapshot from public,anon,authenticated;
grant select on public.bridge_readiness_snapshot to service_role;

create or replace function public.maintain_emergency_bridge()
returns void language plpgsql security definer set search_path=public,pg_catalog as $$
begin
  update public.bridge_nodes set status='offline',updated_at=now()
  where status in ('online','degraded') and last_seen_at<now()-interval '15 minutes';
  update public.bridge_controls set enabled=false,reason=reason||' [expired automatically]',updated_by='maintenance',updated_at=now()
  where enabled and expires_at is not null and expires_at<=now();
  delete from public.bridge_request_ledger where created_at<now()-interval '30 days';
  delete from public.bridge_events where created_at<now()-interval '90 days';
end;
$$;
revoke all on function public.maintain_emergency_bridge() from public,anon,authenticated;
grant execute on function public.maintain_emergency_bridge() to postgres,service_role;

create extension if not exists pg_cron with schema extensions;
select cron.unschedule(jobid) from cron.job where jobname='maintain-emergency-bridge';
select cron.schedule('maintain-emergency-bridge','*/5 * * * *',$$select public.maintain_emergency_bridge();$$);
