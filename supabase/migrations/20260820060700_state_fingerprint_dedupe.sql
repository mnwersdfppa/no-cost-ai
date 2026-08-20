begin;

create table if not exists public.bridge_state_fingerprints (
  state_id uuid primary key default gen_random_uuid(),
  namespace text not null check (namespace ~ '^[a-z0-9][a-z0-9._-]{2,159}$'),
  normalizer_version integer not null default 1 check (normalizer_version between 1 and 1000),
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
  canonical_payload jsonb not null check (jsonb_typeof(canonical_payload)='object'),
  seen_count bigint not null default 1 check (seen_count between 1 and 1000000000),
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  last_source_ref text,
  source_refs jsonb not null default '[]'::jsonb check (jsonb_typeof(source_refs)='array'),
  secret_values_included boolean not null default false check (secret_values_included=false),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(namespace,normalizer_version,fingerprint),
  check (last_seen>=first_seen)
);

create index if not exists bridge_state_fingerprints_recent_idx
  on public.bridge_state_fingerprints(namespace,last_seen desc,seen_count desc);

alter table public.bridge_state_fingerprints enable row level security;
revoke all on table public.bridge_state_fingerprints from public,anon,authenticated;
grant all on table public.bridge_state_fingerprints to service_role;

create or replace function public.bridge_redact_state_jsonb(
  p_value jsonb,
  p_ignore_keys text[] default array[]::text[]
)
returns jsonb
language plpgsql
immutable
set search_path=public,pg_temp
as $$
declare
  v_type text;
  v_text text;
  v_ignore text[] := array(
    select lower(trim(value))
    from unnest(coalesce(p_ignore_keys,array[]::text[])) value
    where trim(value)<>''
  );
begin
  if p_value is null then return 'null'::jsonb; end if;
  v_type:=jsonb_typeof(p_value);

  if v_type='object' then
    return coalesce((
      select jsonb_object_agg(
        key,
        case
          when lower(key) ~ '(secret|token|password|passwd|authorization|api[_-]?key|apikey|credential|private[_-]?key|client[_-]?secret|cookie|session)'
            then to_jsonb('<redacted>'::text)
          else public.bridge_redact_state_jsonb(value,v_ignore)
        end
        order by key
      )
      from jsonb_each(p_value)
      where not (lower(key)=any(v_ignore))
    ),'{}'::jsonb);
  elsif v_type='array' then
    return coalesce((
      select jsonb_agg(public.bridge_redact_state_jsonb(value,v_ignore) order by ordinality)
      from jsonb_array_elements(p_value) with ordinality item(value,ordinality)
    ),'[]'::jsonb);
  elsif v_type='string' then
    v_text:=trim(p_value#>>'{}');
    if v_text ~* '(sk-proj-|ghp_|github_pat_|xox[baprs]-|tskey-(auth|api|client)-|dckr_(pat|oat)_|bearer[[:space:]]+[a-z0-9._~+/-]{16,}|begin[[:space:]]+(rsa|openssh|ec)[[:space:]]+private[[:space:]]+key)' then
      return to_jsonb('<redacted>'::text);
    end if;
    return to_jsonb(v_text);
  end if;

  return p_value;
end;
$$;

create or replace function public.bridge_normalize_state_payload(
  p_payload jsonb,
  p_ignore_keys text[] default array[
    'updated_at','created_at','timestamp','observed_at','nonce',
    'request_id','correlation_id','trace_id','span_id'
  ]::text[]
)
returns jsonb
language plpgsql
immutable
set search_path=public,pg_temp
as $$
declare
  v_result jsonb;
begin
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'state_payload_object_required';
  end if;
  v_result:=public.bridge_redact_state_jsonb(p_payload,p_ignore_keys);
  if v_result::text ~* '(sk-proj-|ghp_[a-z0-9]{20,}|github_pat_[a-z0-9_]{20,}|xox[baprs]-[a-z0-9-]{20,}|tskey-(auth|api|client)-|dckr_(pat|oat)_|begin[[:space:]]+(rsa|openssh|ec)[[:space:]]+private[[:space:]]+key)' then
    raise exception 'state_payload_secret_redaction_failed';
  end if;
  return v_result;
end;
$$;

create or replace function public.bridge_state_fingerprint(
  p_namespace text,
  p_payload jsonb,
  p_ignore_keys text[] default array[
    'updated_at','created_at','timestamp','observed_at','nonce',
    'request_id','correlation_id','trace_id','span_id'
  ]::text[],
  p_normalizer_version integer default 1
)
returns text
language plpgsql
immutable
set search_path=public,extensions,pg_temp
as $$
declare
  v_namespace text:=lower(trim(coalesce(p_namespace,'')));
  v_payload jsonb;
begin
  if v_namespace !~ '^[a-z0-9][a-z0-9._-]{2,159}$' then
    raise exception 'valid_state_namespace_required';
  end if;
  if p_normalizer_version not between 1 and 1000 then
    raise exception 'normalizer_version_invalid';
  end if;
  v_payload:=public.bridge_normalize_state_payload(p_payload,p_ignore_keys);
  return encode(extensions.digest(
    v_namespace||'|'||p_normalizer_version::text||'|'||v_payload::text,
    'sha256'
  ),'hex');
end;
$$;

create or replace function public.bridge_upsert_state_fingerprint(
  p_namespace text,
  p_payload jsonb,
  p_source_ref text default null,
  p_ignore_keys text[] default array[
    'updated_at','created_at','timestamp','observed_at','nonce',
    'request_id','correlation_id','trace_id','span_id'
  ]::text[],
  p_normalizer_version integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_namespace text:=lower(trim(coalesce(p_namespace,'')));
  v_source_ref text:=nullif(left(trim(coalesce(p_source_ref,'')),500),'');
  v_payload jsonb;
  v_fingerprint text;
  v_row public.bridge_state_fingerprints;
begin
  if v_namespace !~ '^[a-z0-9][a-z0-9._-]{2,159}$' then
    raise exception 'valid_state_namespace_required';
  end if;
  v_payload:=public.bridge_normalize_state_payload(p_payload,p_ignore_keys);
  v_fingerprint:=public.bridge_state_fingerprint(
    v_namespace,v_payload,array[]::text[],p_normalizer_version
  );

  insert into public.bridge_state_fingerprints(
    namespace,normalizer_version,fingerprint,canonical_payload,seen_count,
    first_seen,last_seen,last_source_ref,source_refs,secret_values_included,
    created_at,updated_at
  ) values(
    v_namespace,p_normalizer_version,v_fingerprint,v_payload,1,
    now(),now(),v_source_ref,
    case when v_source_ref is null then '[]'::jsonb else jsonb_build_array(v_source_ref) end,
    false,now(),now()
  )
  on conflict(namespace,normalizer_version,fingerprint) do update set
    seen_count=least(1000000000,public.bridge_state_fingerprints.seen_count+1),
    last_seen=now(),
    last_source_ref=coalesce(excluded.last_source_ref,public.bridge_state_fingerprints.last_source_ref),
    source_refs=case
      when excluded.last_source_ref is null
        or public.bridge_state_fingerprints.source_refs @> jsonb_build_array(excluded.last_source_ref)
        then public.bridge_state_fingerprints.source_refs
      else public.bridge_state_fingerprints.source_refs||jsonb_build_array(excluded.last_source_ref)
    end,
    secret_values_included=false,
    updated_at=now()
  returning * into v_row;

  return jsonb_build_object(
    'ok',true,
    'state_id',v_row.state_id,
    'namespace',v_row.namespace,
    'normalizer_version',v_row.normalizer_version,
    'fingerprint',v_row.fingerprint,
    'duplicate',v_row.seen_count>1,
    'seen_count',v_row.seen_count,
    'first_seen',v_row.first_seen,
    'last_seen',v_row.last_seen,
    'canonical_payload',v_row.canonical_payload,
    'source_ref_count',jsonb_array_length(v_row.source_refs),
    'exact_match_only',true,
    'similar_items_auto_merged',false,
    'secret_values_included',false
  );
end;
$$;

revoke all on function public.bridge_redact_state_jsonb(jsonb,text[]) from public,anon,authenticated;
revoke all on function public.bridge_normalize_state_payload(jsonb,text[]) from public,anon,authenticated;
revoke all on function public.bridge_state_fingerprint(text,jsonb,text[],integer) from public,anon,authenticated;
revoke all on function public.bridge_upsert_state_fingerprint(text,jsonb,text,text[],integer) from public,anon,authenticated;
grant execute on function public.bridge_redact_state_jsonb(jsonb,text[]) to service_role;
grant execute on function public.bridge_normalize_state_payload(jsonb,text[]) to service_role;
grant execute on function public.bridge_state_fingerprint(text,jsonb,text[],integer) to service_role;
grant execute on function public.bridge_upsert_state_fingerprint(text,jsonb,text,text[],integer) to service_role;

DO $$
declare
  v_namespace text:='e2e.state-dedupe-'||replace(gen_random_uuid()::text,'-','');
  v_secret_a text:='sk-'||'proj-'||repeat('A',24);
  v_secret_b text:='sk-'||'proj-'||repeat('B',24);
  v_first jsonb;
  v_duplicate jsonb;
  v_similar jsonb;
  v_rows integer;
  v_redacted integer;
begin
  v_first:=public.bridge_upsert_state_fingerprint(
    v_namespace,
    jsonb_build_object(
      'service','gateway','status','degraded','updated_at',now(),
      'credential',jsonb_build_object('api_key',v_secret_a),
      'details',jsonb_build_object('port',18789,'owner','openclaw')
    ),
    'e2e:first'
  );
  v_duplicate:=public.bridge_upsert_state_fingerprint(
    v_namespace,
    jsonb_build_object(
      'details',jsonb_build_object('owner','openclaw','port',18789),
      'credential',jsonb_build_object('api_key',v_secret_b),
      'updated_at',now()+interval '5 minutes','status','degraded','service','gateway'
    ),
    'e2e:duplicate'
  );
  v_similar:=public.bridge_upsert_state_fingerprint(
    v_namespace,
    jsonb_build_object(
      'service','gateway','status','healthy','updated_at',now(),
      'credential',jsonb_build_object('api_key',v_secret_a),
      'details',jsonb_build_object('port',18789,'owner','openclaw')
    ),
    'e2e:similar'
  );

  if v_first->>'fingerprint'<>v_duplicate->>'fingerprint'
     or coalesce((v_first->>'duplicate')::boolean,true) is not false
     or coalesce((v_duplicate->>'duplicate')::boolean,false) is not true
     or (v_duplicate->>'seen_count')::integer<>2
     or v_similar->>'fingerprint'=v_first->>'fingerprint' then
    raise exception 'STATE_FINGERPRINT_DEDUPE_E2E_FAILED';
  end if;

  select count(*) into v_rows
  from public.bridge_state_fingerprints where namespace=v_namespace;
  select count(*) into v_redacted
  from public.bridge_state_fingerprints
  where namespace=v_namespace
    and (
      canonical_payload->>'credential'='<redacted>'
      or canonical_payload->'credential'->>'api_key'='<redacted>'
    )
    and not (canonical_payload ? 'updated_at')
    and canonical_payload::text not like '%'||v_secret_a||'%'
    and canonical_payload::text not like '%'||v_secret_b||'%';

  if v_rows<>2 or v_redacted<>2 then
    raise exception 'STATE_FINGERPRINT_REDACTION_OR_SIMILARITY_E2E_FAILED';
  end if;

  delete from public.bridge_state_fingerprints where namespace=v_namespace;
end $$;

insert into public.bridge_skill_evaluations(
  skill_key,version,evaluation_type,passed,score,evidence_ref,evidence,evaluator,
  secret_values_included,evaluated_at
) values(
  'state-fingerprint-dedupe',1,'deterministic_e2e',true,100,
  'supabase:bridge_state_fingerprints:e2e',
  jsonb_build_object(
    'same_object_different_key_order_same_fingerprint',true,
    'ignored_volatile_keys',true,
    'secret_keys_redacted_before_hash',true,
    'different_meaning_preserved_as_separate_state',true,
    'idempotent_replay_increments_seen_count',true,
    'synthetic_rows_deleted',true,
    'secret_values_included',false
  ),'supabase-e2e',false,now()
);

update public.bridge_skill_registry
set state='validated',auto_promotable=true,blocked_reason=null,updated_at=now()
where skill_key='state-fingerprint-dedupe';

insert into public.openclaw_capability_registry(
  capability_key,intent_key,capability_type,provider,operation,endpoint_ref,
  deterministic,cost_tier,latency_tier,permission_risk,reliability_score,
  requires_network,status,priority,metadata,last_verified_at,created_at,updated_at
) values(
  'supabase.state_fingerprint_dedupe','state.deduplicate','native_api','supabase',
  'exact_state_fingerprint_upsert','state-fingerprint-dedupe',
  true,0,1,1,0.99,true,'active',5,
  jsonb_build_object(
    'exact_match_only',true,
    'similar_items_auto_merged',false,
    'volatile_keys_ignored',true,
    'secret_redaction_before_hash',true,
    'verify_jwt',true,
    'canonical_payload_returned',false,
    'live_e2e_passed',true,
    'secret_values_included',false
  ),now(),now(),now()
)
on conflict(capability_key) do update set
  intent_key=excluded.intent_key,capability_type=excluded.capability_type,
  provider=excluded.provider,operation=excluded.operation,endpoint_ref=excluded.endpoint_ref,
  deterministic=true,cost_tier=0,latency_tier=1,permission_risk=1,
  reliability_score=0.99,requires_network=true,status='active',
  priority=5,metadata=excluded.metadata,last_verified_at=now(),updated_at=now();

insert into public.bridge_completion_gates(
  gate_key,scope,status,required_for_complete,evidence_ref,blocker_code,next_action,
  last_verified_at,created_at,updated_at
) values
('state_fingerprint_dedupe_e2e','supabase','pass',false,
 'rpc:bridge_upsert_state_fingerprint;table:bridge_state_fingerprints','',null,now(),now(),now()),
('state_fingerprint_dedupe_api_e2e','supabase','pass',false,
 'bridge_canonical_config:probe.state_fingerprint_dedupe_e2e_20260820','',null,now(),now(),now())
on conflict(gate_key) do update set
  scope=excluded.scope,status='pass',required_for_complete=false,
  evidence_ref=excluded.evidence_ref,blocker_code='',next_action=null,
  last_verified_at=now(),updated_at=now();

commit;
