-- Refresh PR #5 and its required CI checks through the public GitHub API.
-- No GitHub token is stored or transmitted by this function.

create or replace function public.refresh_github_pr5_gate()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_pr_response extensions.http_response;
  v_runs_response extensions.http_response;
  v_pr jsonb;
  v_runs jsonb;
  v_head_sha text;
  v_draft boolean;
  v_state text;
  v_expected text[] := array[
    'Supabase emergency bridge safety checks',
    'Supabase emergency bridge v2 checks',
    'Supabase emergency Pi client checks'
  ];
  v_name text;
  v_run jsonb;
  v_evidence jsonb := '[]'::jsonb;
  v_success integer := 0;
  v_failure integer := 0;
  v_pending integer := 0;
  v_missing integer := 0;
  v_ci_status text;
  v_result jsonb;
begin
  v_pr_response := extensions.http((
    'GET'::extensions.http_method,
    'https://api.github.com/repos/mnwersdfppa/no-cost-ai/pulls/5'::varchar,
    array[
      row('User-Agent'::varchar,'OpenClaw-Supabase-Bridge/1.0'::varchar)::extensions.http_header,
      row('Accept'::varchar,'application/vnd.github+json'::varchar)::extensions.http_header,
      row('X-GitHub-Api-Version'::varchar,'2022-11-28'::varchar)::extensions.http_header
    ],
    'application/json'::varchar,
    null::varchar
  )::extensions.http_request);

  if v_pr_response.status <> 200 then
    update public.bridge_rollout_gates
    set status='pending',
        blocking_reason='GitHub PR metadata could not be refreshed.',
        next_action='Retry the GitHub public metadata probe.',
        evidence=jsonb_build_object('http_status',v_pr_response.status,'secret_values_checked',false),
        evidence_source='github_public_api',
        updated_at=now()
    where gate_key='github.pr5_ci';
    return jsonb_build_object('status','pending','pr_http_status',v_pr_response.status);
  end if;

  v_pr := v_pr_response.content::jsonb;
  v_head_sha := v_pr #>> '{head,sha}';
  v_draft := coalesce((v_pr->>'draft')::boolean,false);
  v_state := v_pr->>'state';

  v_runs_response := extensions.http((
    'GET'::extensions.http_method,
    'https://api.github.com/repos/mnwersdfppa/no-cost-ai/actions/runs?branch=feat%2Fsupabase-emergency-bridge-20260819&per_page=50'::varchar,
    array[
      row('User-Agent'::varchar,'OpenClaw-Supabase-Bridge/1.0'::varchar)::extensions.http_header,
      row('Accept'::varchar,'application/vnd.github+json'::varchar)::extensions.http_header,
      row('X-GitHub-Api-Version'::varchar,'2022-11-28'::varchar)::extensions.http_header
    ],
    'application/json'::varchar,
    null::varchar
  )::extensions.http_request);

  if v_runs_response.status <> 200 then
    update public.bridge_rollout_gates
    set status='pending',
        blocking_reason='GitHub workflow metadata could not be refreshed.',
        next_action='Retry after GitHub public API availability recovers.',
        evidence=jsonb_build_object('head_sha',v_head_sha,'http_status',v_runs_response.status,'secret_values_checked',false),
        evidence_source='github_public_api',
        updated_at=now()
    where gate_key='github.pr5_ci';
    return jsonb_build_object('status','pending','runs_http_status',v_runs_response.status,'head_sha',v_head_sha);
  end if;

  v_runs := v_runs_response.content::jsonb;

  foreach v_name in array v_expected
  loop
    select value
    into v_run
    from jsonb_array_elements(coalesce(v_runs->'workflow_runs','[]'::jsonb))
    where value->>'name'=v_name
      and value->>'head_sha'=v_head_sha
    order by (value->>'created_at')::timestamptz desc
    limit 1;

    if v_run is null then
      v_missing := v_missing + 1;
      v_evidence := v_evidence || jsonb_build_array(jsonb_build_object(
        'name',v_name,'status','missing','conclusion',null
      ));
    else
      v_evidence := v_evidence || jsonb_build_array(jsonb_build_object(
        'name',v_name,
        'status',v_run->>'status',
        'conclusion',v_run->>'conclusion',
        'run_id',v_run->>'id',
        'url',v_run->>'html_url'
      ));

      if v_run->>'status' <> 'completed' then
        v_pending := v_pending + 1;
      elsif v_run->>'conclusion' = 'success' then
        v_success := v_success + 1;
      else
        v_failure := v_failure + 1;
      end if;
    end if;
  end loop;

  v_ci_status := case
    when v_failure > 0 then 'fail'
    when v_pending > 0 or v_missing > 0 then 'pending'
    when v_success = cardinality(v_expected) then 'pass'
    else 'pending'
  end;

  insert into public.bridge_rollout_gates(
    gate_key,component,status,blocking_reason,next_action,evidence,evidence_source
  ) values (
    'github.pr5_ci','GitHub',v_ci_status,
    case
      when v_ci_status='pass' then null
      when v_ci_status='fail' then 'One or more required PR #5 workflow checks failed.'
      else 'Required PR #5 workflow checks are pending or missing for the current head.'
    end,
    case
      when v_ci_status='pass' then 'Keep PR #5 Draft until physical Pi and downstream gates pass.'
      when v_ci_status='fail' then 'Inspect the failed workflow logs and repair the branch.'
      else 'Wait for or dispatch the required workflow checks.'
    end,
    jsonb_build_object(
      'head_sha',v_head_sha,
      'draft',v_draft,
      'state',v_state,
      'expected_checks',cardinality(v_expected),
      'successful',v_success,
      'failed',v_failure,
      'pending',v_pending,
      'missing',v_missing,
      'runs',v_evidence,
      'secret_values_checked',false
    ),
    'github_public_api'
  ) on conflict (gate_key) do update set
    status=excluded.status,
    blocking_reason=excluded.blocking_reason,
    next_action=excluded.next_action,
    evidence=excluded.evidence,
    evidence_source=excluded.evidence_source,
    updated_at=now();

  update public.bridge_rollout_gates
  set status='blocked',
      blocking_reason=case
        when v_state<>'open' then 'PR #5 is not open.'
        when not v_draft then 'PR #5 is no longer Draft before physical completion evidence.'
        when v_ci_status<>'pass' then 'Required CI is not yet passing for the current head.'
        else 'Physical Pi authentication, heartbeat, phone T3 and Telegram T4 remain required.'
      end,
      next_action=case
        when v_ci_status<>'pass' then 'Complete the required PR workflow checks.'
        else 'Complete physical Pi, phone and Telegram evidence before merge.'
      end,
      evidence=jsonb_build_object(
        'pr_number',5,
        'head_sha',v_head_sha,
        'state',v_state,
        'draft',v_draft,
        'ci_status',v_ci_status,
        'merged',false
      ),
      evidence_source='github_public_api',
      updated_at=now()
  where gate_key='github.pr5_merge';

  perform public.refresh_bridge_rollout_gates();

  v_result := jsonb_build_object(
    'status',v_ci_status,
    'head_sha',v_head_sha,
    'draft',v_draft,
    'state',v_state,
    'successful',v_success,
    'failed',v_failure,
    'pending',v_pending,
    'missing',v_missing,
    'generated_at',now()
  );
  return v_result;
exception when others then
  insert into public.bridge_rollout_gates(
    gate_key,component,status,blocking_reason,next_action,evidence,evidence_source
  ) values (
    'github.pr5_ci','GitHub','pending',
    'GitHub CI refresh raised a bounded error.',
    'Retry the public metadata refresh.',
    jsonb_build_object('error_class',sqlstate,'secret_values_checked',false),
    'github_public_api'
  ) on conflict (gate_key) do update set
    status='pending',
    blocking_reason=excluded.blocking_reason,
    next_action=excluded.next_action,
    evidence=excluded.evidence,
    evidence_source=excluded.evidence_source,
    updated_at=now();
  return jsonb_build_object('status','pending','error_class',sqlstate,'generated_at',now());
end;
$$;

revoke all on function public.refresh_github_pr5_gate()
  from public,anon,authenticated;
grant execute on function public.refresh_github_pr5_gate()
  to postgres,service_role;

select public.refresh_github_pr5_gate();
