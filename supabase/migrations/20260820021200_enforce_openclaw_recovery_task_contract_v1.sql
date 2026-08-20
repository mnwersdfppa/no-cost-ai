create or replace function private.enforce_openclaw_recovery_task_contract()
returns trigger
language plpgsql
security definer
set search_path=public,pg_catalog
as $$
declare
  v_expected_type text;
  v_executable_keys text[] := array['command','commands','shell','argv','executable'];
begin
  v_expected_type := case new.task_key
    when 'pi-supabase-auth-model-recovery-v3' then 'pi_supabase_auth_model_recovery'
    when 'queue-worker-liveness-guardian-v1' then 'worker_liveness_guardian'
    when 'telegram-rate-limit-local-failover-v1' then 'telegram_model_failover_repair'
    else null
  end;

  if v_expected_type is not null then
    new.task_type := v_expected_type;
    new.priority := 100;
    new.max_attempts := greatest(1,least(coalesce(new.max_attempts,5),5));
  end if;

  if new.task_key='telegram-model-session-unpin-v1' then
    new.task_type := 'telegram_model_session_recovery';
    new.status := 'cancelled';
    new.priority := 0;
    new.lease_until := null;
    new.claimed_by := null;
    new.completed_at := coalesce(new.completed_at,now());
    new.last_error := 'manual_telegram_session_model_override_reset_required';
  end if;

  if new.task_type in (
    'pi_supabase_auth_model_recovery',
    'worker_liveness_guardian',
    'telegram_model_failover_repair'
  ) then
    if coalesce(new.payload,'{}'::jsonb) ?| v_executable_keys then
      raise exception 'executable payload fields are forbidden for deterministic recovery tasks'
        using errcode='22023';
    end if;
    if coalesce((new.payload->>'arbitrary_payload_commands_allowed')::boolean,false) then
      raise exception 'arbitrary payload commands are forbidden for deterministic recovery tasks'
        using errcode='22023';
    end if;
    if new.status='queued' then
      new.claimed_by := null;
      new.lease_until := null;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.enforce_openclaw_recovery_task_contract() from public,anon,authenticated;

drop trigger if exists openclaw_recovery_task_contract_guard on public.openclaw_work_queue;
create trigger openclaw_recovery_task_contract_guard
before insert or update of task_key,task_type,payload,priority,max_attempts,status,claimed_by,lease_until,completed_at,last_error
on public.openclaw_work_queue
for each row
execute function private.enforce_openclaw_recovery_task_contract();

comment on function private.enforce_openclaw_recovery_task_contract() is
'Normalizes canonical OpenClaw recovery task types and rejects executable payload fields before queue persistence.';
