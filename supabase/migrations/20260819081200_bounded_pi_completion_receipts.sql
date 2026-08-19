-- Allow a pi-gateway-client to submit one bounded non-secret canonical-config
-- receipt. Phone, Telegram, and rollback completion remain service-role verified.

insert into public.bridge_permission_policies(
  policy_key,integration,operation,risk_tier,enabled,approval_required,
  max_calls_per_hour,max_payload_bytes,notes
) values (
  'supabase.completion_receipt',
  'supabase_platform',
  'completion_receipt',
  1,
  true,
  false,
  30,
  16384,
  'Accepts only bounded, non-secret Pi evidence for the canonical-config E2E gate. Phone, Telegram, and rollback gates remain service-role verified.'
) on conflict (integration,operation) do update set
  risk_tier=excluded.risk_tier,
  enabled=true,
  approval_required=false,
  max_calls_per_hour=excluded.max_calls_per_hour,
  max_payload_bytes=excluded.max_payload_bytes,
  notes=excluded.notes,
  updated_at=now();

create or replace function public.bridge_accept_pi_completion_receipt(
  p_user_id uuid,
  p_gate_key text,
  p_correlation_id text,
  p_evidence_sha256 text,
  p_evidence jsonb default '{}'::jsonb
)
returns public.bridge_completion_gates
language plpgsql
security definer
set search_path=public,auth,private,pg_catalog
as $$
declare
  v_role text;
  v_row public.bridge_completion_gates;
  v_redacted jsonb;
begin
  select raw_app_meta_data->>'role'
  into v_role
  from auth.users
  where id=p_user_id;

  if v_role<>'pi-gateway-client' then
    raise exception 'pi identity required';
  end if;

  if p_gate_key<>'canonical_config_pi_e2e' then
    raise exception 'gate not accepted from Pi receipt';
  end if;

  if p_correlation_id is null
     or length(p_correlation_id) not between 8 and 128 then
    raise exception 'invalid correlation id';
  end if;

  if p_evidence_sha256 is null
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid evidence sha256';
  end if;

  if pg_column_size(coalesce(p_evidence,'{}'::jsonb))>16384 then
    raise exception 'evidence too large';
  end if;

  v_redacted:=private.bridge_redact_jsonb(coalesce(p_evidence,'{}'::jsonb));

  if coalesce(v_redacted->>'project_ref','')<>'dpllasnpfskyyyzebyal'
     or coalesce((v_redacted->>'server_secret_returned')::boolean,true)<>false
     or coalesce((v_redacted->>'legacy_anon_fallback_enabled')::boolean,true)<>false
     or coalesce((v_redacted->>'vercel_raw_token_fallback_enabled')::boolean,true)<>false
     or coalesce((v_redacted->>'paid_api_fallback')::boolean,true)<>false
     or coalesce((v_redacted->>'telegram_single_poller_enforced')::boolean,false)<>true then
    raise exception 'canonical configuration evidence failed policy';
  end if;

  update public.bridge_completion_gates
  set status='pass',
      evidence_ref='pi-receipt:canonical-config:'||p_evidence_sha256,
      blocker_code=null,
      next_action=null,
      last_verified_at=now(),
      updated_at=now()
  where gate_key=p_gate_key
  returning * into v_row;

  if not found then
    raise exception 'completion gate missing';
  end if;

  perform public.bridge_record_event(
    'pi_completion_receipt',
    'raspberry-pi5',
    p_correlation_id,
    'info',
    'succeeded',
    jsonb_build_object(
      'gate_key',p_gate_key,
      'evidence_sha256',p_evidence_sha256,
      'evidence',v_redacted,
      'secret_values_included',false
    )
  );

  return v_row;
end;
$$;

revoke all on function public.bridge_accept_pi_completion_receipt(uuid,text,text,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.bridge_accept_pi_completion_receipt(uuid,text,text,text,jsonb)
  to service_role;

create or replace function public.bridge_admit_request(
  p_user_id uuid,
  p_action text,
  p_execution_key text default null
)
returns table(
  allowed boolean,
  duplicate boolean,
  reason text,
  limit_per_hour integer,
  observed_last_hour bigint
)
language plpgsql
security definer
set search_path=public,auth,pg_catalog
as $$
declare
  v_role text;
  v_operation text;
  v_policy public.bridge_permission_policies;
  v_emergency_enabled boolean;
  v_existing public.bridge_request_ledger;
  v_count bigint;
begin
  select raw_app_meta_data->>'role' into v_role
  from auth.users where id=p_user_id;

  if v_role<>'pi-gateway-client' then
    return query select false,false,'pi_identity_required',0,0::bigint;
    return;
  end if;

  if p_action is null or length(p_action)<1 or length(p_action)>80 then
    return query select false,false,'invalid_action',0,0::bigint;
    return;
  end if;

  v_operation:=case p_action
    when 'status' then 'status'
    when 'heartbeat' then 'heartbeat'
    when 'policy_check' then 'policy_check'
    when 'queue_status' then 'queue_status'
    when 'credential_readiness' then 'credential_readiness'
    when 'resolve_route' then 'resolve_route'
    when 'completion_receipt' then 'completion_receipt'
    else null
  end;

  if v_operation is null then
    return query select false,false,'unsupported_action',0,0::bigint;
    return;
  end if;

  select enabled into v_emergency_enabled
  from public.bridge_controls where control_key='emergency_bridge';

  if coalesce(v_emergency_enabled,false)=false then
    return query select false,false,'emergency_bridge_disabled',0,0::bigint;
    return;
  end if;

  if p_execution_key is not null then
    if length(p_execution_key)>128 then
      return query select false,false,'execution_key_too_long',0,0::bigint;
      return;
    end if;

    select * into v_existing
    from public.bridge_request_ledger
    where user_id=p_user_id and execution_key=p_execution_key;

    if found then
      return query select v_existing.allowed,true,'duplicate_execution_key',0,0::bigint;
      return;
    end if;
  end if;

  select * into v_policy
  from public.bridge_permission_policies
  where integration='supabase_platform' and operation=v_operation;

  if not found or v_policy.enabled=false then
    insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason)
    values(p_user_id,p_action,p_execution_key,false,'policy_disabled');
    return query select false,false,'policy_disabled',0,0::bigint;
    return;
  end if;

  select count(*) into v_count
  from public.bridge_request_ledger
  where user_id=p_user_id and action=p_action
    and created_at>=now()-interval '1 hour';

  if v_policy.max_calls_per_hour=0 or v_count>=v_policy.max_calls_per_hour then
    insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason)
    values(p_user_id,p_action,p_execution_key,false,'rate_limit_exceeded');
    return query select false,false,'rate_limit_exceeded',v_policy.max_calls_per_hour,v_count;
    return;
  end if;

  insert into public.bridge_request_ledger(user_id,action,execution_key,allowed,reason)
  values(p_user_id,p_action,p_execution_key,true,'admitted');

  return query select true,false,'admitted',v_policy.max_calls_per_hour,v_count;
end;
$$;

revoke all on function public.bridge_admit_request(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.bridge_admit_request(uuid,text,text)
  to service_role;
