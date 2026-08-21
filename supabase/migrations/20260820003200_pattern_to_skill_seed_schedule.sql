begin;

DO $$
declare
  r record;
begin
  for r in
    select
      event_type,
      count(*)::integer as occurrences,
      min(created_at) as first_seen,
      max(created_at) as last_seen,
      bool_or(severity in ('warning','error','critical') or outcome in ('failed','blocked')) as problematic,
      jsonb_build_object(
        'severities',jsonb_agg(distinct severity),
        'outcomes',jsonb_agg(distinct outcome),
        'source','bridge_events_aggregate',
        'raw_detail_copied',false,
        'secret_values_included',false
      ) as context
    from public.bridge_events
    group by event_type
  loop
    perform public.bridge_record_pattern_observation(
      'supabase_event',r.event_type,
      case when r.problematic then 'error' else 'workflow' end,
      'Bridge event pattern: '||r.event_type,
      'Aggregated bridge event occurrence. Raw event detail is intentionally excluded from the pattern store.',
      r.event_type,r.context,r.occurrences,r.first_seen,r.last_seen,
      case when r.problematic then 900 else 200 end,
      case when r.problematic then 300 else 30 end,
      case when r.problematic then 75 else 35 end::smallint,
      80::smallint,90::smallint,95::smallint,
      case when r.problematic then 30 else 10 end::smallint,
      null
    );
  end loop;
end $$;

DO $$
declare
  r record;
begin
  for r in
    select
      blocker_code,
      count(*)::integer as occurrences,
      min(coalesce(last_verified_at,created_at)) as first_seen,
      max(coalesce(last_verified_at,updated_at)) as last_seen,
      bool_or(required_for_complete) as required,
      jsonb_build_object(
        'gate_keys',jsonb_agg(gate_key order by gate_key),
        'required_for_complete',bool_or(required_for_complete),
        'source','bridge_completion_gates',
        'secret_values_included',false
      ) as context
    from public.bridge_completion_gates
    where status in ('pending','fail','blocked')
      and coalesce(blocker_code,'')<>''
    group by blocker_code
  loop
    perform public.bridge_record_pattern_observation(
      'completion_gate',r.blocker_code,'availability',
      'Completion gate blocker: '||r.blocker_code,
      'A completion gate remains unresolved. The pattern stores only the blocker code and gate identifiers.',
      r.blocker_code,r.context,r.occurrences,r.first_seen,r.last_seen,
      case when r.required then 1800 else 700 end,
      case when r.required then 1800 else 600 end,
      case when r.required then 92 else 65 end::smallint,
      70::smallint,80::smallint,95::smallint,35::smallint,null
    );
  end loop;
end $$;

DO $$
declare
  r record;
begin
  for r in
    select
      left(last_error,240) as last_error,
      count(*)::integer as occurrences,
      min(created_at) as first_seen,
      max(updated_at) as last_seen,
      jsonb_build_object(
        'task_types',jsonb_agg(distinct task_type),
        'statuses',jsonb_agg(distinct status),
        'source','openclaw_work_queue_aggregate',
        'payload_copied',false,
        'secret_values_included',false
      ) as context
    from public.openclaw_work_queue
    where coalesce(last_error,'')<>''
    group by left(last_error,240)
  loop
    perform public.bridge_record_pattern_observation(
      'work_queue',r.last_error,'error',
      'Work queue error: '||left(r.last_error,180),
      'Aggregated work-queue error. Task payloads and credentials are excluded.',
      r.last_error,r.context,r.occurrences,r.first_seen,r.last_seen,
      1200,600,80::smallint,85::smallint,85::smallint,90::smallint,35::smallint,null
    );
  end loop;
end $$;

DO $$
declare
  row record;
begin
  for row in
    select * from (values
      ('Unavailable model remained pinned in agents.defaults.model',
       'configured_model_unavailable',18,94,95,92,97,20,2200,900,
       'OpenClaw agents.defaults.model unavailable model automatic validation and fallback configuration'),
      ('Duplicate free-model fallback collapsed to the same provider and model',
       'duplicate_fallback_route',16,90,96,95,95,18,1800,600,
       'Deduplicate AI model fallback routes by provider and model identifier'),
      ('Pi refresh-token length guard rejected valid current-format tokens',
       'refresh_token_length_guard_mismatch',9,96,94,92,99,45,3500,1800,
       'Supabase current refresh token format client-side minimum length validation'),
      ('Provider overload or unavailability was surfaced directly to Telegram',
       'raw_provider_overload_to_telegram',22,93,96,90,96,25,1600,600,
       'Durable queue and safe acknowledgement for AI provider HTTP 429 and 503 in a Telegram bot'),
      ('Telegram inbound poller duplication risk',
       'duplicate_telegram_poller',12,95,90,88,98,75,2400,1200,
       'Single Telegram long-polling consumer distributed lock and duplicate getUpdates prevention'),
      ('Installer operating-system or CPU architecture mismatch',
       'installer_platform_mismatch',11,86,92,96,94,25,1600,900,
       'Docker multi-platform linux arm64 amd64 compatibility validation for Raspberry Pi'),
      ('Supabase secret alias drift between legacy and modern key names',
       'supabase_secret_alias_drift',10,88,90,92,96,65,2200,1200,
       'Supabase modern publishable and secret keys with legacy service-role compatibility migration'),
      ('GitHub workflow created a self-commit trigger loop',
       'github_actions_self_commit_loop',7,80,95,98,98,20,1200,600,
       'Prevent a GitHub Actions workflow from self-committing and retriggering indefinitely'),
      ('Split installer source and SHA-256 values drifted apart',
       'installer_sha_source_drift',13,91,94,95,98,30,2000,1200,
       'SHA-pinned installer composition with immutable artifact verification and rollback'),
      ('Notion was used as an operational database before Supabase became the SSOT',
       'notion_operational_db_to_supabase_ssot',8,72,82,85,85,50,3000,3600,
       'Migrate a Notion operational database to a normalized Supabase single source of truth'),
      ('Physical Raspberry Pi dependency blocked otherwise complete cloud recovery',
       'physical_pi_dependency',24,92,72,75,96,55,2600,7200,
       'Remote Raspberry Pi recovery API heartbeat Tailscale and OpenClaw gateway control'),
      ('Repeated reasoning was used where a deterministic API or adapter could be called',
       'api_first_automation_gap',30,88,98,95,90,35,4200,900,
       'API-first automation that replaces repeated LLM reasoning with deterministic tool calls'),
      ('Docker credential was stored as English instructions with an embedded token',
       'composite_secret_instruction_format',3,78,90,90,95,70,2600,1800,
       'Safely parse a composite credential instruction without returning or logging the secret'),
      ('Vercel was considered for a long-running runtime worker despite serverless boundaries',
       'vercel_runtime_role_mismatch',6,67,92,96,92,20,1000,300,
       'Separate serverless status UI from long-running Telegram polling and model retry workers'),
      ('Temporary E2E identities or tasks could leak into readiness state',
       'temporary_e2e_artifact_leak',8,74,96,98,99,25,900,300,
       'Automatically clean temporary E2E users queues and evidence artifacts after tests')
    ) as v(title,error_code,occurrences,impact,automation,reversibility,confidence,risk,tokens,recovery_seconds,english_query)
  loop
    perform public.bridge_record_pattern_observation(
      'manual','project-history-inferred',
      case
        when row.error_code='installer_platform_mismatch' then 'compatibility'
        when row.error_code in ('composite_secret_instruction_format','supabase_secret_alias_drift') then 'credential'
        when row.error_code='api_first_automation_gap' then 'repeated_reasoning'
        else 'error'
      end,
      row.title,
      'Repeated project-history pattern. Occurrence count is a conservative operational estimate rather than a raw transcript count.',
      row.error_code,
      jsonb_build_object(
        'frequency_basis','conservative_project_history_estimate',
        'raw_conversation_copied',false,
        'secret_values_included',false
      ),
      row.occurrences,now()-interval '60 days',now(),
      row.tokens,row.recovery_seconds,row.impact::smallint,row.automation::smallint,
      row.reversibility::smallint,row.confidence::smallint,row.risk::smallint,null
    );
    update public.bridge_pattern_candidates
    set english_query=row.english_query,
        translation_state='verified',
        state=case when priority_score>=45 and risk_score<=70 then 'ready_for_research' else 'observed' end,
        updated_at=now()
    where canonical_title=row.title;
  end loop;
end $$;

insert into public.bridge_skill_registry(
  skill_key,display_name,category,description,state,risk_tier,auto_promotable,
  current_version,trigger_policy,input_schema,output_schema,permissions,
  required_gates,rollback_strategy,owner_component,activated_at,
  secret_values_included,created_at,updated_at
) values
('model.route.guardian','Model Route Guardian','retry',
 'Validate configured model identifiers, deduplicate routes, quarantine failing models and preserve requests.',
 'active','low',false,1,'{"on_model_request":true}'::jsonb,'{}'::jsonb,'{}'::jsonb,
 '["provider_call","queue_write"]'::jsonb,
 array['static_security','deterministic_e2e','rollback'],
 '{"strategy":"disable_guardian_route_and_restore_previous_config"}'::jsonb,
 'edge.pi-model-gateway-guardian',now(),false,now(),now()),
('pi.auth.refresh.guardian','Pi Session Refresh Guardian','credential',
 'Rotate only scoped pi-gateway-client sessions and reject all other roles.',
 'active','medium',false,1,'{"before_pi_api_call":true,"on_http_401":true}'::jsonb,
 '{}'::jsonb,'{}'::jsonb,'["scoped_token_rotation"]'::jsonb,
 array['static_security','deterministic_e2e','secret_boundary','rollback'],
 '{"strategy":"discard_new_session_and_keep_existing_refresh_token"}'::jsonb,
 'edge.pi-auth-refresh',now(),false,now(),now()),
('provider.overload.queue','Provider Overload Queue','retry',
 'Replace raw 429/503 failures with durable queueing, bounded backoff and a safe Telegram acknowledgement.',
 'active','low',false,1,'{"on_http":[429,503],"on_timeout":true}'::jsonb,
 '{}'::jsonb,'{}'::jsonb,'["provider_call","queue_write","telegram_outbound"]'::jsonb,
 array['static_security','deterministic_e2e','rollback'],
 '{"strategy":"disable_retry_cron_and_leave_tasks_queued"}'::jsonb,
 'edge.model-retry-worker',now(),false,now(),now()),
('telegram.single-poller.guard','Telegram Single-Poller Guard','validation',
 'Prevent creation of a second inbound Telegram polling consumer.',
 'active','low',true,1,'{"on_deploy":true,"on_config_change":true}'::jsonb,
 '{}'::jsonb,'{}'::jsonb,'["read_config","static_validation"]'::jsonb,
 array['static_security','deterministic_e2e','rollback'],
 '{"strategy":"reject_change"}'::jsonb,'github-ci',now(),false,now(),now()),
('installer.integrity.sha256','Installer Integrity Guard','validation',
 'Download artifacts to files, verify exact SHA-256 and contract markers, then execute only verified installers.',
 'active','low',true,1,'{"on_installer_download":true}'::jsonb,
 '{}'::jsonb,'{}'::jsonb,'["read_file","hash_file","execute_verified_artifact"]'::jsonb,
 array['static_security','deterministic_e2e','rollback'],
 '{"strategy":"abort_before_execution"}'::jsonb,
 'edge.pi-openclaw-current-master-recovery-verified',now(),false,now(),now()),
('e2e.artifact.cleanup','E2E Artifact Cleanup','deduplication',
 'Remove only explicitly tagged temporary identities, queues and evidence after tests.',
 'active','low',true,1,'{"after_e2e":true}'::jsonb,
 '{}'::jsonb,'{}'::jsonb,'["delete_temporary_test_rows_only"]'::jsonb,
 array['static_security','deterministic_e2e','rollback'],
 '{"strategy":"transaction_rollback_or_tag_scoped_restore"}'::jsonb,
 'supabase-test-harness',now(),false,now(),now()),
('pattern.to.skill.sweeper','Pattern-to-Skill Sweeper','classification',
 'Score repeated patterns, queue English research queries and metadata-promote only low-risk skills that pass all gates.',
 'validated','low',true,1,'{"schedule":"*/30 * * * *"}'::jsonb,
 '{}'::jsonb,'{}'::jsonb,'["read_patterns","write_research_queue","metadata_promotion"]'::jsonb,
 array['static_security','schema_validation','deterministic_e2e','rollback'],
 '{"strategy":"unschedule_cron_and_restore_previous_skill_state"}'::jsonb,
 'supabase-pattern-control-plane',null,false,now(),now()),
('research.search-before-build','Search Before Build Planner','classification',
 'Generate one cached English query per fingerprint and search approved sources before proposing code.',
 'validated','low',true,1,'{"on_candidate_ready":true}'::jsonb,
 '{}'::jsonb,'{}'::jsonb,'["read_candidates","write_research_queue"]'::jsonb,
 array['static_security','schema_validation','deterministic_e2e','rollback'],
 '{"strategy":"delete_unclaimed_research_tasks"}'::jsonb,
 'supabase-pattern-control-plane',null,false,now(),now()),
('api.first.capability.router','API-First Capability Router','read_only_api',
 'Prefer an existing typed API, RPC, MCP, CLI adapter or container contract over repeated free-form reasoning.',
 'proposed','low',true,1,'{"on_new_task":true}'::jsonb,
 '{}'::jsonb,'{}'::jsonb,'["read_capability_registry"]'::jsonb,
 array['static_security','schema_validation','deterministic_e2e','rollback'],
 '{"strategy":"return_to_reasoning_without_side_effect"}'::jsonb,
 'openclaw-orchestrator',null,false,now(),now()),
('notion.supabase.ssot.migration','Notion-to-Supabase SSOT Migration','migration',
 'Classify Notion records, copy normalized operational data to Supabase, verify checksums and retain source pages.',
 'proposed','medium',false,1,'{"manual_batch_only":true}'::jsonb,
 '{}'::jsonb,'{}'::jsonb,'["notion_read","supabase_insert","checksum_verify"]'::jsonb,
 array['static_security','schema_validation','deterministic_e2e','rollback','manual_review'],
 '{"strategy":"retain_notion_source_and_delete_only_unverified_staging_rows"}'::jsonb,
 'knowledge-migration',null,false,now(),now())
on conflict(skill_key) do update set
  display_name=excluded.display_name,category=excluded.category,
  description=excluded.description,
  state=case when bridge_skill_registry.state='active' then 'active' else excluded.state end,
  risk_tier=excluded.risk_tier,auto_promotable=excluded.auto_promotable,
  current_version=greatest(bridge_skill_registry.current_version,excluded.current_version),
  trigger_policy=excluded.trigger_policy,input_schema=excluded.input_schema,
  output_schema=excluded.output_schema,permissions=excluded.permissions,
  required_gates=excluded.required_gates,rollback_strategy=excluded.rollback_strategy,
  owner_component=excluded.owner_component,
  activated_at=coalesce(bridge_skill_registry.activated_at,excluded.activated_at),
  secret_values_included=false,updated_at=now();

insert into public.bridge_skill_versions(
  skill_key,version,semantic_version,definition,source_ref,status,
  immutable,created_by,secret_values_included,created_at
)
select
  skill_key,1,'1.0.0',
  jsonb_build_object(
    'display_name',display_name,
    'category',category,
    'description',description,
    'trigger_policy',trigger_policy,
    'input_schema',input_schema,
    'output_schema',output_schema,
    'permissions',permissions,
    'required_gates',to_jsonb(required_gates),
    'rollback_strategy',rollback_strategy,
    'arbitrary_payload_execution',false,
    'secret_values_included',false
  ),
  owner_component,
  case when state='active' then 'active' when state='canary' then 'canary' else 'candidate' end,
  true,'supabase-seed',false,now()
from public.bridge_skill_registry
where current_version=1
on conflict(skill_key,version) do nothing;

insert into public.bridge_capability_registry(
  capability_key,provider,capability_type,status,endpoint_ref,auth_location,cost_tier,
  permissions,supported_platforms,use_cases,fallback_capability_keys,evidence,
  selected,secret_values_included,last_verified_at,created_at,updated_at
) values
('supabase.postgres.rpc','supabase','rpc','selected','public.bridge_pattern_skill_readiness','supabase_service_role_edge_only','included',
 '["read","bounded_write"]'::jsonb,array['cloud'],
 '["ssot","scoring","queue","skill_registry","audit"]'::jsonb,array[]::text[],
 '{"project_id":"dpllasnpfskyyyzebyal","rls":true,"secret_values_included":false}'::jsonb,true,false,now(),now(),now()),
('supabase.edge.functions','supabase','edge_function','selected','functions/v1','supabase_edge_env','included',
 '["typed_http","secret_isolation"]'::jsonb,array['cloud'],
 '["gateway","auth_refresh","readiness","bounded_workers"]'::jsonb,array['supabase.postgres.rpc'],
 '{"provider_secret_location":"supabase_edge_only","secret_values_included":false}'::jsonb,true,false,now(),now(),now()),
('github.contents.actions','github','api','selected','mnwersdfppa/no-cost-ai','connected_connector','included',
 '["read_repository","draft_branch_write","actions_read"]'::jsonb,array['cloud'],
 '["source_control","ci","immutable_evidence"]'::jsonb,array['supabase.postgres.rpc'],
 '{"pull_request":5,"draft":true,"automatic_merge":false,"secret_values_included":false}'::jsonb,true,false,now(),now(),now()),
('docker.registry.api','docker_hub','api','verified','registry-1.docker.io','supabase_edge:Docker-api-key','free',
 '["pull","namespace_push"]'::jsonb,array['cloud','linux/arm64','linux/amd64'],
 '["multiarch_image_publish","portable_runtime"]'::jsonb,array['docker.engine.api'],
 '{"repository":"odifool/openclaw-compat","credential_exported":false,"secret_values_included":false}'::jsonb,true,false,now(),now(),now()),
('docker.engine.api','docker','api','discovered','local_docker_socket','pi_host_only','free',
 '["pull","run_hardened_container"]'::jsonb,array['linux/arm64','linux/amd64'],
 '["platform_compatibility","artifact_validation"]'::jsonb,array['raspberrypi.host.adapter'],
 '{"physical_pi_audit_required":true,"socket_mount_default":false,"secret_values_included":false}'::jsonb,false,false,null,now(),now()),
('openclaw.gateway.api','openclaw','api','discovered','local_gateway','pi_scoped_session','included',
 '["status","model_config","bounded_restart"]'::jsonb,array['linux/arm64'],
 '["gateway_health","model_activation","telegram_bridge"]'::jsonb,array['raspberrypi.host.adapter'],
 '{"physical_pi_e2e_required":true,"secret_values_included":false}'::jsonb,false,false,null,now(),now()),
('raspberrypi.host.adapter','raspberry_pi','host_adapter','discovered','~/.local/bin/openclaw-host-adapter','local_user','included',
 '["systemd_user","tailscale_cli","ollama_cli","openclaw_cli"]'::jsonb,array['linux/arm64'],
 '["host_daemon_control","hardware_access","receipt_collection"]'::jsonb,array['docker.engine.api'],
 '{"arbitrary_shell":false,"fixed_handlers_only":true,"physical_pi_e2e_required":true,"secret_values_included":false}'::jsonb,false,false,null,now(),now()),
('notion.connected.api','notion','api','connected','connected_notion_workspace','connected_connector','included',
 '["read","explicit_write"]'::jsonb,array['cloud'],
 '["knowledge_source","migration_source"]'::jsonb,array['supabase.postgres.rpc'],
 '{"operational_ssot":false,"source_retention_required":true,"secret_values_included":false}'::jsonb,false,false,now(),now(),now()),
('n8n.workflow.api','n8n','workflow','discovered','n8n_api_or_webhook','credential_pending','unknown',
 '["workflow_run","webhook","error_workflow"]'::jsonb,array['linux/arm64','linux/amd64','cloud'],
 '["deterministic_orchestration","connectors","error_handling"]'::jsonb,array['supabase.edge.functions'],
 '{"connection_audit_required":true,"secret_values_included":false}'::jsonb,false,false,null,now(),now()),
('langgraph.workflow.runtime','langgraph','workflow','discovered','library_runtime','application_managed','free',
 '["state_machine","checkpoint","human_gate"]'::jsonb,array['linux/arm64','linux/amd64','cloud'],
 '["durable_agent_flow","promotion_state_machine"]'::jsonb,array['supabase.postgres.rpc'],
 '{"dependency_and_license_verification_required":true,"secret_values_included":false}'::jsonb,false,false,null,now(),now()),
('langsmith.observability','langsmith','api','discovered','observability_api','credential_pending','unknown',
 '["trace_write","evaluation"]'::jsonb,array['cloud'],
 '["reasoning_trace_metrics","skill_evaluation"]'::jsonb,array['supabase.postgres.rpc'],
 '{"cost_and_data_policy_review_required":true,"secret_values_included":false}'::jsonb,false,false,null,now(),now()),
('mcp.capability.adapters','mcp','mcp','discovered','typed_mcp_servers','per_server','free',
 '["tool_discovery","typed_call"]'::jsonb,array['linux/arm64','linux/amd64','cloud'],
 '["api_first_routing","capability_registry"]'::jsonb,array['supabase.edge.functions'],
 '{"server_allowlist_required":true,"secret_values_included":false}'::jsonb,false,false,null,now(),now())
on conflict(capability_key) do update set
  provider=excluded.provider,capability_type=excluded.capability_type,
  status=excluded.status,endpoint_ref=excluded.endpoint_ref,
  auth_location=excluded.auth_location,cost_tier=excluded.cost_tier,
  permissions=excluded.permissions,supported_platforms=excluded.supported_platforms,
  use_cases=excluded.use_cases,fallback_capability_keys=excluded.fallback_capability_keys,
  evidence=excluded.evidence,selected=excluded.selected,secret_values_included=false,
  last_verified_at=excluded.last_verified_at,updated_at=now();

insert into public.bridge_canonical_config(
  config_key,config_value,sensitivity,enabled,source,notes,created_at,updated_at
) values
('pattern_skill.policy',jsonb_build_object(
  'loop',jsonb_build_array(
    'observe','deduplicate','score','translate_once','search_existing',
    'sandbox','evaluate','canary','promote','monitor','rollback_or_revise'
  ),
  'search_before_build',true,
  'english_query_cached_by_fingerprint',true,
  'auto_promotable_categories',jsonb_build_array(
    'validation','deduplication','retry','cache','classification','read_only_api',
    'schema_check','health_check','reporting','compatibility','migration'
  ),
  'manual_gate_categories',jsonb_build_array('credential','network','deployment','host_control'),
  'forbidden_auto_permissions',jsonb_build_array(
    'root','sudo','arbitrary_exec','credential_scope_change','secret_export',
    'public_network','data_delete','billing','paid_api','telegram_poll','merge',
    'prod_deploy','docker_socket','privileged'
  ),
  'minimum_gates',jsonb_build_array('static_security','deterministic_e2e','rollback'),
  'active_canary_minimum_minutes',30,
  'active_canary_minimum_successes',3,
  'audit_receipt_required',true,
  'hidden_infrastructure',false,
  'unauthorized_access',false,
  'secret_values_included',false
),'non_secret',true,'pattern-to-skill-control-plane',
 'Reversible pattern-to-skill promotion policy. Promotion changes metadata only and never executes arbitrary code.',
 now(),now()),
('notion.supabase.migration_policy',jsonb_build_object(
  'source','notion',
  'destination','supabase',
  'supabase_is_operational_ssot',true,
  'notion_role','human_readable_knowledge_and_archive',
  'migration_order',jsonb_build_array(
    'discover','classify','stage','copy','checksum','verify','retain_source','optional_archive'
  ),
  'delete_source_automatically',false,
  'migrate_operational_tables_first',true,
  'migrate_secrets',false,
  'secret_values_included',false
),'non_secret',true,'pattern-to-skill-control-plane',
 'Notion content is never deleted automatically. Operational records move only after schema and checksum verification.',
 now(),now()),
('api_first.routing_policy',jsonb_build_object(
  'order',jsonb_build_array(
    'existing_typed_api','existing_rpc','existing_mcp','existing_cli_adapter',
    'verified_container_contract','cached_skill','bounded_reasoning'
  ),
  'reasoning_is_fallback_not_default',true,
  'capability_registry_required',true,
  'idempotency_required_for_writes',true,
  'receipt_required_for_side_effects',true,
  'secret_values_included',false
),'non_secret',true,'pattern-to-skill-control-plane',
 'Prefer deterministic capabilities over repeated free-form inference while preserving authorization and auditability.',
 now(),now())
on conflict(config_key) do update set
  config_value=excluded.config_value,sensitivity='non_secret',enabled=true,
  source=excluded.source,notes=excluded.notes,updated_at=now();

DO $$
declare
  r record;
begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    for r in select jobid from cron.job where jobname='openclaw-pattern-skill-sweeper-v1' loop
      perform cron.unschedule(r.jobid);
    end loop;
    perform cron.schedule(
      'openclaw-pattern-skill-sweeper-v1',
      '*/30 * * * *',
      'select public.bridge_pattern_skill_sweep();'
    );
  end if;
end $$;

select public.bridge_score_pattern_candidates();
select public.bridge_enqueue_pattern_research(50);

commit;
