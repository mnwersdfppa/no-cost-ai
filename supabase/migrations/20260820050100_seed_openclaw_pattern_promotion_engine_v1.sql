begin;

insert into public.openclaw_pattern_rules(
  rule_key,source_kind,match_regex,pattern_key,category,priority,
  default_tokens_saved,default_minutes_saved,enabled
) values
('event.provider_overload','bridge_event','(model_gateway_guardian|model_retry|provider|model_health|overload|rate_limit|429|503)','provider-overload-failover','routing',300,600,8,true),
('event.auth_identity','bridge_event','(pi_auth_refresh|auth|credential|device_identity|reapproval|token_refresh)','pi-auth-device-identity-recovery','credential',290,900,15,true),
('event.telegram_delivery','bridge_event','(telegram|result_delivery|single_poller|message_send)','telegram-response-recovery','operation',280,500,10,true),
('event.gateway_liveness','bridge_event','(gateway|port_18789|restart_storm|worker_liveness|liveness)','gateway-port-restart-guard','error',270,800,15,true),
('event.runtime_compatibility','bridge_event','(docker|container|compatibility|multiarch|architecture|arm64|amd64)','runtime-compatibility-resolver','compatibility',260,900,20,true),
('event.artifact_integrity','bridge_event','(github|workflow|artifact|integrity|sha256|ci_)','artifact-integrity-validation','observability',250,500,8,true),
('event.queue_retry','bridge_event','(queue|retry|recovery|backoff|scheduler)','durable-queue-retry','operation',240,600,10,true),
('event.observability','bridge_event','(readiness|heartbeat|status|observability|reconciled)','api-first-status-routing','observability',180,250,3,true),
('queue.auth_recovery','work_queue','(pi_supabase_auth_model_recovery|pi_infrastructure_recovery)','pi-auth-device-identity-recovery','credential',300,1000,20,true),
('queue.telegram_recovery','work_queue','(telegram_model_failover_repair|telegram_model_session_recovery|telegram_result_delivery)','telegram-response-recovery','operation',290,700,12,true),
('queue.liveness','work_queue','worker_liveness_guardian','gateway-port-restart-guard','error',280,700,12,true),
('queue.route_reprobe','work_queue','model_route_reprobe','provider-overload-failover','routing',270,500,8,true),
('queue.second_brain','work_queue','second_brain_(dedupe|recovery_guard|telegram_roundtrip|memory_contract|projection_sync|feedback_loop|master)','second-brain-dedupe-recovery','data_quality',260,900,15,true),
('queue.integration_index','work_queue','(integration_secret_index|credential|secret)','credential-readiness-guard','credential',230,500,8,true),
('request.credential_readiness','request_ledger','credential_readiness','credential-readiness-guard','credential',300,250,3,true),
('request.status','request_ledger','(status|heartbeat|queue_status|canonical_client_config|canonical_config)','api-first-status-routing','observability',280,200,2,true),
('request.duplicate','request_ledger','true:(duplicate_execution_key|duplicate|already)','state-fingerprint-dedupe','data_quality',320,400,5,true),
('decision.approval','command_decision','(approved|approval|standing_approval|single_approval)','approval-chain-orchestrator','approval',280,500,8,true),
('decision.command_center','command_decision','supabase.command_center','api-first-status-routing','routing',250,300,4,true)
on conflict(rule_key) do update set
  source_kind=excluded.source_kind,match_regex=excluded.match_regex,pattern_key=excluded.pattern_key,
  category=excluded.category,priority=excluded.priority,default_tokens_saved=excluded.default_tokens_saved,
  default_minutes_saved=excluded.default_minutes_saved,enabled=true,updated_at=now();

insert into public.openclaw_pattern_candidates(
  pattern_key,title_ko,title_en,category,description,automation_target,status,risk_level,
  deterministic,reversible,requires_approval,manual_status_lock,ci_state,e2e_state,skill_name,
  macro_spec,skill_spec,preconditions,rollback_spec,verification_spec,route_policy,current_version
) values
(
 'provider-overload-failover','모델 과부하·폐기 모델 자동 우회','Provider overload and unavailable-model failover','routing',
 'Quarantine unhealthy models, try only distinct verified routes and durably queue the original request on total failure.',
 'deterministic_macro','macro_candidate','low',true,true,false,false,'pass','pass','provider-failover-guardian',
 jsonb_build_object('trigger',jsonb_build_array(429,503,'timeout','model_not_found'),'max_immediate_attempts',2,'queue_on_total_failure',true),
 jsonb_build_object('runtime','supabase_guardian','raw_provider_error_to_telegram',false),
 jsonb_build_object('canonical_route_present',true,'durable_queue_present',true),
 jsonb_build_object('disable_pattern',true,'restore_previous_model_route',true,'preserve_queued_requests',true),
 jsonb_build_object('tests',jsonb_build_array('primary_success','fallback_success','all_failure_queue_ack','no_duplicate_model_attempt','no_secret_return')),
 jsonb_build_object('first','supabase_guardian','fallback','local_ollama_after_pi_verification','paid_fallback',false),1
),
(
 'pi-auth-device-identity-recovery','Pi 인증·기기 신원 자동 복구','Pi authentication and device identity recovery','credential',
 'Refresh a scoped Pi session and classify device-identity reapproval separately from network failure.',
 'deterministic_macro','macro_candidate','low',true,true,false,false,'pass','pass','pi-auth-identity-recovery',
 jsonb_build_object('trigger',jsonb_build_array(401,'expired_access_token','device_identity_reapproval'),'retry_once',true),
 jsonb_build_object('runtime','supabase_auth_plus_pi_host_adapter','minimum_refresh_token_chars',8,'auth_server_validation_required',true),
 jsonb_build_object('existing_refresh_token',true,'expected_role','pi-gateway-client'),
 jsonb_build_object('restore_previous_session_file',true,'delete_temporary_tokens',true,'do_not_export_service_role',true),
 jsonb_build_object('tests',jsonb_build_array('current_format_refresh','invalid_refresh_rejected','role_mismatch_rejected','temporary_identity_cleanup')),
 jsonb_build_object('first','pi-auth-refresh','then','pi-infra-bootstrap','manual_gate','new_device_identity_approval_only'),1
),
(
 'telegram-response-recovery','Telegram 무응답·전달 실패 복구','Telegram no-response and delivery recovery','operation',
 'Preserve one inbound poller, persist results and deliver through an outbound-only queue worker.',
 'deterministic_macro','macro_candidate','low',true,true,false,false,'pass','pass','telegram-single-poller-recovery',
 jsonb_build_object('single_inbound_poller',true,'outbound_only',true,'bounded_retry',true),
 jsonb_build_object('delivery_command','openclaw message send','direct_get_updates',false),
 jsonb_build_object('telegram_existing_configuration',true,'pi_session',true),
 jsonb_build_object('disable_outbound_timer',true,'never_delete_existing_bot_config',true),
 jsonb_build_object('tests',jsonb_build_array('single_poller','queue_pull','outbound_send','dedupe_delivery_key')),
 jsonb_build_object('first','existing_openclaw_telegram','server_fallback','durable_result_queue'),1
),
(
 'gateway-port-restart-guard','Gateway 18789 포트·재시작 폭주 방지','Gateway port 18789 and restart-storm guard','error',
 'Classify UI lag, stopped work, port ownership and gateway health before a bounded known-service restart.',
 'host_adapter','macro_candidate','low',true,true,false,false,'pending','pending','gateway-liveness-guard',
 jsonb_build_object('read_only_preflight',true,'max_restart_per_window',1,'stability_window_minutes',10),
 jsonb_build_object('runtime','pi_host_adapter','unknown_process_kill',false),
 jsonb_build_object('systemd_user_available',true,'openclaw_cli_available',true),
 jsonb_build_object('restore_previous_unit_state',true,'never_kill_unknown_pid',true),
 jsonb_build_object('tests',jsonb_build_array('healthy_noop','ui_lag_no_restart','unknown_port_owner_block','restart_storm_block')),
 jsonb_build_object('first','openclaw_gateway_status_api','fallback','systemd_host_adapter','container_for_host_control',false),1
),
(
 'state-fingerprint-dedupe','동일 상태·기록·제안 중복 제거','State fingerprint deduplication','data_quality',
 'Normalize state and reuse an exact intent or decision instead of creating another record.',
 'deterministic_macro','macro_candidate','low',true,true,false,false,'pending','pending','state-fingerprint-dedupe',
 jsonb_build_object('steps',jsonb_build_array('canonicalize','redact','sha256','lookup','reuse_or_insert','increment_seen_count'),'similarity_policy','exact_only_auto_merge'),
 jsonb_build_object('authoritative_store','supabase','notion_role','projection_only'),
 jsonb_build_object('stable_normalizer_version',true),
 jsonb_build_object('retain_original_rows',true,'never_delete_similar_content_automatically',true),
 jsonb_build_object('tests',jsonb_build_array('exact_duplicate_reused','similar_item_preserved','idempotent_replay')),
 jsonb_build_object('first','supabase_fingerprint_rpc','projection','notion'),1
),
(
 'approval-chain-orchestrator','반복 승인 단일 체인화','Standing approval chain orchestrator','approval',
 'Reuse explicit approval only inside the same bounded scope and keep cost, destructive and public-exposure gates separate.',
 'deterministic_macro','macro_candidate','medium',true,true,true,false,'pending','pending','standing-approval-orchestrator',
 jsonb_build_object('approval_reuse','scope_and_fingerprint_bound','implicit_global_approval',false),
 jsonb_build_object('runtime','command_center_decision'),
 jsonb_build_object('explicit_scope',true,'approval_not_expired',true),
 jsonb_build_object('cancel_remaining_steps',true,'preserve_completed_receipts',true),
 jsonb_build_object('tests',jsonb_build_array('same_scope_reuse','changed_scope_reapproval','cost_gate','destructive_gate')),
 jsonb_build_object('first','command_center_decision','policy','opa_candidate','manual_gate','high_risk_only'),1
),
(
 'runtime-compatibility-resolver','운영체제·아키텍처·패키지 불일치 자동 해결','Runtime compatibility resolver','compatibility',
 'Select verified native execution, hardened multi-architecture Docker, or a fixed host adapter; unknown combinations fail closed.',
 'container','verified','low',true,true,false,true,'pass','pass','runtime-compatibility-resolver',
 jsonb_build_object('resolution_order',jsonb_build_array('verified_native','verified_docker_multiarch','verified_host_adapter','blocked'),'platforms',jsonb_build_array('linux/arm64','linux/amd64')),
 jsonb_build_object('container_defaults',jsonb_build_object('read_only',true,'network','none','user','65532:65532','cap_drop','ALL','docker_socket',false),'host_control_in_container',false),
 jsonb_build_object('profile_registered',true),
 jsonb_build_object('preserve_existing_runtime',true,'remove_only_named_container',true),
 jsonb_build_object('tests',jsonb_build_array('arm64_resolution','amd64_resolution','unknown_arch_block','credential_free_image')),
 jsonb_build_object('first','native_if_verified','portable','docker_multiarch','privileged','host_adapter'),1
),
(
 'artifact-integrity-validation','설치기·워크플로·산출물 무결성 검증','Artifact and workflow integrity validation','observability',
 'Verify exact digest, size, syntax and contract markers before execution or promotion.',
 'deterministic_macro','verified','low',true,true,false,true,'pass','pass','artifact-integrity-validator',
 jsonb_build_object('steps',jsonb_build_array('download_to_file','verify_sha256','verify_size','syntax_check','contract_scan'),'curl_pipe_shell',false),
 jsonb_build_object('runtimes',jsonb_build_array('github_actions','supabase_edge','docker_compat_runner')),
 jsonb_build_object('expected_digest',true,'contract_markers',true),
 jsonb_build_object('discard_unverified_artifact',true,'preserve_previous_version',true),
 jsonb_build_object('tests',jsonb_build_array('digest_match','digest_mismatch_block','secret_literal_block','syntax_error_block')),
 jsonb_build_object('first','github_actions','runtime_recheck','docker_compat_runner'),1
),
(
 'durable-queue-retry','영속 큐·가시성 제한·지수 백오프','Durable queue and bounded retry','operation',
 'Use durable Postgres work records, atomic claims, leases, bounded retry and archival.',
 'deterministic_macro','verified','low',true,true,false,true,'pass','pass','durable-queue-retry',
 jsonb_build_object('queue','openclaw_work_queue','backoff_seconds',jsonb_build_array(120,300,900,2700,7200),'idempotency_key',true),
 jsonb_build_object('runtime','supabase_postgres','pgmq_available',true,'pg_cron_available',true),
 jsonb_build_object('task_type_allowlist',true,'max_attempts',true),
 jsonb_build_object('release_lease',true,'requeue_safe_tasks',true,'archive_completed',true),
 jsonb_build_object('tests',jsonb_build_array('atomic_claim','lease_expiry','duplicate_key','bounded_failure')),
 jsonb_build_object('first','supabase_queue_rpc','scheduler','pg_cron','pi_worker','scoped_pull'),1
),
(
 'notion-ssot-projection','Notion을 Supabase SSOT 읽기용 투영본으로 전환','Notion as a projection of Supabase SSOT','data_quality',
 'Keep machine-authoritative state in Supabase and retain Notion as a human projection and historical evidence store.',
 'deterministic_macro','macro_candidate','low',true,true,false,false,'pending','pending','notion-ssot-projection-guard',
 jsonb_build_object('authoritative_store','supabase','projection_store','notion','delete_policy','never_auto_delete_history'),
 jsonb_build_object('projection_interval','event_driven_or_15min','state_fingerprint',true),
 jsonb_build_object('notion_connector_available',true,'supabase_schema_ready',true),
 jsonb_build_object('disable_projection_job',true,'retain_notion_pages',true),
 jsonb_build_object('tests',jsonb_build_array('one_projection_per_key','manual_notion_notes_preserved','supabase_remains_authoritative')),
 jsonb_build_object('write','supabase_first','project','notion_connector','read_machine','supabase_api'),1
),
(
 'api-first-status-routing','상태·자격증명·큐 조회를 API 우선으로 전환','API-first status and readiness routing','routing',
 'Use deterministic APIs, MCP tools and connectors before model reasoning.',
 'deterministic_macro','macro_candidate','low',true,true,false,false,'pending','pending','api-first-capability-router',
 jsonb_build_object('order',jsonb_build_array('native_api','mcp','connector','deterministic_macro','host_adapter','container','local_model','cloud_model','manual')),
 jsonb_build_object('selection',jsonb_build_object('deterministic_first',true,'lowest_permission_risk',true,'lowest_cost',true,'highest_reliability',true)),
 jsonb_build_object('capability_registry_populated',true),
 jsonb_build_object('disable_route',true,'fallback_to_previous_resolver',true),
 jsonb_build_object('tests',jsonb_build_array('status_uses_api','credential_check_no_llm','unknown_intent_manual','no_secret_in_response')),
 jsonb_build_object('registry','openclaw_capability_registry','resolver','openclaw_resolve_capability'),1
),
(
 'second-brain-dedupe-recovery','제2의 뇌 중복 제거·복구·피드백 루프','Second-brain deduplication, recovery and feedback loop','data_quality',
 'Separate canonical memory, projections, recovery receipts and feedback to avoid repeated reading or recreation.',
 'durable_workflow','observe','medium',true,true,true,false,'not_tested','not_tested','second-brain-memory-loop',
 jsonb_build_object('stages',jsonb_build_array('ingest','normalize','fingerprint','canonical_upsert','projection','feedback','retention')),
 jsonb_build_object('checkpoint_candidate','langgraph','semantic_index','pgvector','authoritative_store','supabase'),
 jsonb_build_object('memory_contract_defined',false),
 jsonb_build_object('retain_raw_ingest_reference',true,'disable_projection',true),
 jsonb_build_object('tests',jsonb_build_array('exact_dedupe','semantic_near_duplicate_review','projection_rebuild','checkpoint_resume')),
 jsonb_build_object('first','supabase_canonical_memory','checkpoint','langgraph_after_verification','projection','notion'),1
),
(
 'credential-readiness-guard','자격증명 존재·형식·권한 사전 점검','Credential readiness guard','credential',
 'Check boolean presence, credential class and required scopes before work; retain raw values in the canonical secret store.',
 'deterministic_macro','macro_candidate','low',true,true,false,false,'pass','pass','credential-readiness-guard',
 jsonb_build_object('steps',jsonb_build_array('resolve_alias','presence_check','classify','scope_probe','record_boolean_readiness'),'return_raw_value',false),
 jsonb_build_object('secret_stores',jsonb_build_array('supabase_edge_env','supabase_vault','github_actions_secrets'),'values_logged',false),
 jsonb_build_object('canonical_alias_registered',true),
 jsonb_build_object('disable_integration',true,'do_not_delete_secret',true),
 jsonb_build_object('tests',jsonb_build_array('missing','valid_readonly','valid_write_scope','wrong_class','no_secret_return')),
 jsonb_build_object('first','credential_readiness_api','then','provider_scope_probe','llm_reasoning',false),1
)
on conflict(pattern_key) do update set
  title_ko=excluded.title_ko,title_en=excluded.title_en,category=excluded.category,description=excluded.description,
  automation_target=excluded.automation_target,risk_level=excluded.risk_level,deterministic=excluded.deterministic,
  reversible=excluded.reversible,requires_approval=excluded.requires_approval,
  status=case when openclaw_pattern_candidates.manual_status_lock then openclaw_pattern_candidates.status else excluded.status end,
  manual_status_lock=openclaw_pattern_candidates.manual_status_lock or excluded.manual_status_lock,
  ci_state=excluded.ci_state,e2e_state=excluded.e2e_state,skill_name=excluded.skill_name,
  macro_spec=excluded.macro_spec,skill_spec=excluded.skill_spec,preconditions=excluded.preconditions,
  rollback_spec=excluded.rollback_spec,verification_spec=excluded.verification_spec,route_policy=excluded.route_policy,
  updated_at=now();

insert into public.openclaw_capability_registry(
  capability_key,intent_key,capability_type,provider,operation,endpoint_ref,deterministic,
  cost_tier,latency_tier,permission_risk,reliability_score,requires_network,status,priority,metadata,last_verified_at
) values
('supabase.command_status','status.read','native_api','supabase','command_status','command-center:command_status',true,0,1,1,0.98,true,'active',10,jsonb_build_object('authoritative',true,'secret_values_returned',false),now()),
('supabase.recovery_readiness','status.read','native_api','supabase','openclaw_recovery_readiness','openclaw-recovery-readiness',true,0,1,1,0.99,true,'active',5,jsonb_build_object('authoritative',true,'cloud_and_physical_gates',true),now()),
('supabase.credential_readiness','credential.check','native_api','supabase','credential_readiness','credential-readiness',true,0,1,1,0.98,true,'active',5,jsonb_build_object('boolean_only',true,'raw_value_returned',false),now()),
('supabase.guardian','model.generate','native_api','supabase','openai_responses_proxy','pi-model-gateway-guardian/v1',false,0,2,1,0.93,true,'active',10,jsonb_build_object('provider_secret','edge_only','bounded_attempts',2,'durable_queue_on_failure',true),now()),
('ollama.qwen25_3b','model.generate','local_model','ollama','generate','ollama/qwen2.5:3b',false,0,3,0,0.75,false,'pending_verification',80,jsonb_build_object('physical_pi_verification_required',true),null),
('supabase.work_queue','work.enqueue','native_api','supabase','enqueue','openclaw_work_queue',true,0,1,1,0.99,true,'active',5,jsonb_build_object('durable',true,'idempotency_key',true),now()),
('supabase.work_queue_claim','work.claim','native_api','supabase','scoped_claim','pi-work-queue',true,0,1,1,0.97,true,'active',5,jsonb_build_object('visibility_lease',true,'task_type_allowlist',true),now()),
('supabase.pg_cron','work.schedule','native_api','supabase','cron_schedule','pg_cron',true,0,1,2,0.97,true,'active',10,jsonb_build_object('single_job_per_purpose',true),now()),
('openclaw.gateway_status','gateway.status','native_api','openclaw','gateway_status','openclaw gateway status',true,0,1,1,0.90,false,'pending_verification',10,jsonb_build_object('physical_pi_required',true),null),
('pi.systemd_host_adapter','gateway.recover','host_adapter','raspberry_pi','bounded_known_unit_recovery','systemd --user',true,0,2,2,0.85,false,'pending_verification',20,jsonb_build_object('unknown_process_kill',false,'max_restart_once',true),null),
('openclaw.telegram_outbound','telegram.send','native_api','openclaw','message_send','openclaw message send --channel telegram',true,0,2,2,0.88,true,'pending_verification',10,jsonb_build_object('outbound_only',true,'get_updates',false),null),
('openclaw.telegram_single_poller','telegram.receive','host_adapter','openclaw','existing_inbound_poller','existing_openclaw_telegram_integration',true,0,2,2,0.90,true,'pending_verification',10,jsonb_build_object('poller_count',1,'new_poller_forbidden',true),null),
('tailscale.cli_enroll','network.private_enroll','host_adapter','tailscale','node_enrollment','tailscale up',true,0,2,3,0.86,true,'pending_verification',20,jsonb_build_object('funnel',false,'one_time_auth_key',true,'management_api',false),null),
('docker.compat_resolver','runtime.compatibility','container','docker','multiarch_compatibility','docker.io/odifool/openclaw-compat',true,0,2,1,0.90,true,'active',10,jsonb_build_object('platforms',jsonb_build_array('linux/arm64','linux/amd64'),'read_only',true,'docker_socket',false),now()),
('pi.host_compat_adapter','runtime.compatibility','host_adapter','raspberry_pi','privileged_host_compatibility','~/.local/bin/openclaw-host-adapter',true,0,2,2,0.82,false,'pending_verification',30,jsonb_build_object('systemd',true,'tailscale',true,'ollama',true),null),
('supabase.ssot_write','memory.canonical_write','native_api','supabase','upsert_canonical_record','command-center',true,0,1,1,0.98,true,'active',5,jsonb_build_object('authoritative',true,'dedupe_fingerprint',true),now()),
('supabase.ssot_read','memory.canonical_read','native_api','supabase','read_canonical_record','command-center',true,0,1,1,0.99,true,'active',5,jsonb_build_object('authoritative',true),now()),
('notion.human_projection','memory.project_human','connector','notion','upsert_projection','Notion connector',true,0,2,2,0.86,true,'active',20,jsonb_build_object('authoritative',false,'projection_only',true,'delete_history',false),now()),
('supabase.pattern_engine','pattern.score','native_api','supabase','refresh_pattern_scores','openclaw_refresh_pattern_scores',true,0,1,1,0.95,false,'active',5,jsonb_build_object('bayesian_feedback',true,'risk_penalty',true),now()),
('github.skill_validation','skill.validate','connector','github_actions','ci_validation','GitHub Actions',true,0,3,2,0.92,true,'active',10,jsonb_build_object('draft_pr_only',true,'automatic_merge',false),now()),
('langgraph.durable_workflow','workflow.durable','deterministic_macro','langgraph','checkpointed_state_graph','optional_component',true,0,3,2,0.70,true,'pending_verification',30,jsonb_build_object('use_for','long_running_interruptible_workflows','not_for','simple_cron_or_single_api_call'),null),
('n8n.external_api_macro','workflow.external_api','connector','n8n','webhook_orchestration','local_n8n',true,0,3,3,0.65,true,'pending_verification',30,jsonb_build_object('use_for','external_api_fanout','queue_mode','only_if_scale_requires'),null),
('otel.collector','observability.emit','deterministic_macro','opentelemetry','otlp_collect','optional_collector',true,0,3,1,0.75,true,'pending_verification',30,jsonb_build_object('signals',jsonb_build_array('traces','metrics','logs'),'batching',true),null),
('opa.policy_engine','policy.evaluate','deterministic_macro','opa','policy_decision','optional_sidecar_or_library',true,0,2,1,0.75,false,'pending_verification',30,jsonb_build_object('use_for','separate_policy_from_execution','default','fail_closed'),null),
('manual.review','unknown.intent','manual','human','review','manual',true,0,5,0,1.0,false,'active',100,jsonb_build_object('reason','no_verified_automatic_capability'),now())
on conflict(capability_key) do update set
  intent_key=excluded.intent_key,capability_type=excluded.capability_type,provider=excluded.provider,
  operation=excluded.operation,endpoint_ref=excluded.endpoint_ref,deterministic=excluded.deterministic,
  cost_tier=excluded.cost_tier,latency_tier=excluded.latency_tier,permission_risk=excluded.permission_risk,
  reliability_score=excluded.reliability_score,requires_network=excluded.requires_network,status=excluded.status,
  priority=excluded.priority,metadata=excluded.metadata,last_verified_at=excluded.last_verified_at,updated_at=now();

insert into public.openclaw_skill_registry(skill_name,status,repo,branch,pr_number,install_path,route_policy,token_policy,updated_at)
values
('pattern-promotion-engine','supabase_cloud_active_github_skill_pending','mnwersdfppa/no-cost-ai','feat/supabase-emergency-bridge-20260819',5,'~/.openclaw/workspace/skills/pattern-promotion-engine',jsonb_build_object('stages',jsonb_build_array('observe','score','macro_candidate','skill_candidate','verified','active'),'automatic_merge',false),jsonb_build_object('llm_required_for_scoring',false,'default_route','deterministic_sql'),now()),
('api-first-capability-router','supabase_cloud_active_pi_install_pending','mnwersdfppa/no-cost-ai','feat/supabase-emergency-bridge-20260819',5,'~/.openclaw/workspace/skills/api-first-capability-router',jsonb_build_object('order',jsonb_build_array('native_api','mcp','connector','deterministic_macro','host_adapter','container','local_model','cloud_model','manual')),'{}'::jsonb,now()),
('state-fingerprint-dedupe','supabase_schema_active_projection_worker_pending','mnwersdfppa/no-cost-ai','feat/supabase-emergency-bridge-20260819',5,'~/.openclaw/workspace/skills/state-fingerprint-dedupe',jsonb_build_object('authoritative_store','supabase','exact_duplicate','reuse','similar_duplicate','review'),'{}'::jsonb,now()),
('notion-ssot-projection-guard','policy_active_projection_sync_pending','mnwersdfppa/no-cost-ai','feat/supabase-emergency-bridge-20260819',5,'~/.openclaw/workspace/skills/notion-ssot-projection-guard',jsonb_build_object('supabase','authoritative','notion','projection_only','automatic_history_delete',false),'{}'::jsonb,now()),
('runtime-compatibility-resolver','cloud_verified_physical_pi_pending','mnwersdfppa/no-cost-ai','feat/supabase-emergency-bridge-20260819',5,'~/.openclaw/workspace/skills/runtime-compatibility-resolver',jsonb_build_object('native_first',true,'docker_for_portable',true,'host_adapter_for_privileged',true,'unknown','blocked'),'{}'::jsonb,now())
on conflict(skill_name) do update set
  status=excluded.status,repo=excluded.repo,branch=excluded.branch,pr_number=excluded.pr_number,
  install_path=excluded.install_path,route_policy=excluded.route_policy,token_policy=excluded.token_policy,updated_at=now();

insert into public.bridge_canonical_config(config_key,config_value,sensitivity,enabled,source,notes,created_at,updated_at)
values
('automation.pattern_promotion',jsonb_build_object(
  'version',1,'authoritative_store','supabase',
  'stages',jsonb_build_array('observe','macro_candidate','skill_candidate','verified','active'),
  'active_requirements',jsonb_build_array('promotion_score_85','risk_low','ci_pass','e2e_pass','rollback_spec','verification_spec','skill_name'),
  'high_risk_auto_promotion',false,'secret_values_included',false
),'non_secret',true,'supabase-pattern-promotion-engine-v1','Pattern to macro to skill promotion policy.',now(),now()),
('routing.api_first',jsonb_build_object(
  'version',1,'order',jsonb_build_array('native_api','mcp','connector','deterministic_macro','host_adapter','container','local_model','cloud_model','manual'),
  'llm_for_known_status_or_credentials',false,'unknown_intent_fail_closed',true
),'non_secret',true,'supabase-capability-registry-v1','API and deterministic capability routing before model reasoning.',now(),now()),
('notion.projection_policy',jsonb_build_object(
  'authoritative_store','supabase','notion_role','human_readable_projection_and_historical_evidence',
  'write_order',jsonb_build_array('supabase_commit','projection_enqueue','notion_upsert'),
  'exact_duplicate_behavior','increment_seen_count','similar_duplicate_behavior','review_only','automatic_deletion',false
),'non_secret',true,'supabase-ssot-policy-v1','Notion is not the machine-authoritative database.',now(),now()),
('open_source.evolution_stack',jsonb_build_object(
  'selected',jsonb_build_object(
    'durable_queue','supabase_postgres_pgmq','scheduler','supabase_pg_cron','portable_runtime','docker_oci_multiarch',
    'long_running_checkpoint_candidate','langgraph','external_api_macro_candidate','n8n',
    'observability_candidate','opentelemetry_collector','policy_candidate','opa','validation','github_actions','human_projection','notion'
  ),'install_rule','only_after_local_need_and_e2e','avoid_duplicate_orchestrators',true,'secret_values_included',false
),'non_secret',true,'official-open-source-analysis-20260820','Optional components remain pending verification until justified.',now(),now())
on conflict(config_key) do update set config_value=excluded.config_value,sensitivity=excluded.sensitivity,enabled=true,source=excluded.source,notes=excluded.notes,updated_at=now();

select public.openclaw_harvest_operational_patterns();
select public.openclaw_refresh_pattern_scores();

do $$
declare v_jobid bigint;
begin
  for v_jobid in select jobid from cron.job where jobname in ('openclaw-pattern-harvest-v1','openclaw-pattern-score-v1') loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule('openclaw-pattern-harvest-v1','*/15 * * * *','select public.openclaw_harvest_operational_patterns();');
  perform cron.schedule('openclaw-pattern-score-v1','7 * * * *','select public.openclaw_refresh_pattern_scores();');
end $$;

commit;
