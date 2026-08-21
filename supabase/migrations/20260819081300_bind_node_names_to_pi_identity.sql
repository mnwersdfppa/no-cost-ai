-- Prevent one Pi identity from overwriting a node name already bound to another
-- identity. Heartbeat payloads remain recursively redacted before storage.

create or replace function public.bridge_record_heartbeat(
  p_user_id uuid,
  p_node_name text,
  p_node_type text,
  p_status text,
  p_capabilities jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns public.bridge_nodes
language plpgsql
security definer
set search_path=public,auth,private,pg_catalog
as $$
declare
  v_role text;
  v_existing_user uuid;
  v_row public.bridge_nodes;
begin
  select raw_app_meta_data ->> 'role'
  into v_role
  from auth.users
  where id=p_user_id;

  if v_role <> 'pi-gateway-client' then
    raise exception 'pi identity required';
  end if;

  if p_node_type not in (
    'raspberry_pi','android_phone','desktop','cloud_worker','unknown'
  ) then
    raise exception 'invalid node type';
  end if;
  if p_status not in ('online','offline','degraded','blocked','unknown') then
    raise exception 'invalid status';
  end if;
  if length(coalesce(p_node_name,'')) not between 1 and 100 then
    raise exception 'invalid node name';
  end if;
  if pg_column_size(coalesce(p_capabilities,'{}'::jsonb))>32768
     or pg_column_size(coalesce(p_metadata,'{}'::jsonb))>32768 then
    raise exception 'payload too large';
  end if;

  select auth_user_id into v_existing_user
  from public.bridge_nodes
  where node_name=p_node_name
  for update;

  if found
     and v_existing_user is not null
     and v_existing_user <> p_user_id then
    raise exception 'node name is bound to another Pi identity';
  end if;

  insert into public.bridge_nodes(
    node_name,node_type,auth_user_id,status,
    capabilities,metadata,last_seen_at
  ) values (
    p_node_name,p_node_type,p_user_id,p_status,
    private.bridge_redact_jsonb(p_capabilities),
    private.bridge_redact_jsonb(p_metadata),
    now()
  )
  on conflict(node_name) do update set
    node_type=excluded.node_type,
    auth_user_id=excluded.auth_user_id,
    status=excluded.status,
    capabilities=excluded.capabilities,
    metadata=excluded.metadata,
    last_seen_at=excluded.last_seen_at,
    updated_at=now()
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.bridge_record_heartbeat(uuid,text,text,text,jsonb,jsonb)
  from public,anon,authenticated;
grant execute on function public.bridge_record_heartbeat(uuid,text,text,text,jsonb,jsonb)
  to service_role;
