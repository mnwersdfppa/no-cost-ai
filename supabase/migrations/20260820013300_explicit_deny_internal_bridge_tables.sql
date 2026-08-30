begin;

-- These tables were already inaccessible to anon/authenticated because RLS was
-- enabled and neither role had table privileges. Explicit restrictive policies
-- preserve that behavior while documenting the server-role-only boundary.

drop policy if exists bridge_completion_gates_internal_deny
  on public.bridge_completion_gates;
create policy bridge_completion_gates_internal_deny
  on public.bridge_completion_gates
  as restrictive
  for all
  to anon, authenticated
  using (false)
  with check (false);

drop policy if exists bridge_model_health_internal_deny
  on public.bridge_model_health;
create policy bridge_model_health_internal_deny
  on public.bridge_model_health
  as restrictive
  for all
  to anon, authenticated
  using (false)
  with check (false);

drop policy if exists bridge_owner_registry_internal_deny
  on public.bridge_owner_registry;
create policy bridge_owner_registry_internal_deny
  on public.bridge_owner_registry
  as restrictive
  for all
  to anon, authenticated
  using (false)
  with check (false);

drop policy if exists bridge_runtime_components_internal_deny
  on public.bridge_runtime_components;
create policy bridge_runtime_components_internal_deny
  on public.bridge_runtime_components
  as restrictive
  for all
  to anon, authenticated
  using (false)
  with check (false);

comment on policy bridge_completion_gates_internal_deny
  on public.bridge_completion_gates is
  'Explicit deny policy for client roles. Internal Edge functions use the server role.';
comment on policy bridge_model_health_internal_deny
  on public.bridge_model_health is
  'Explicit deny policy for client roles. Internal Edge functions use the server role.';
comment on policy bridge_owner_registry_internal_deny
  on public.bridge_owner_registry is
  'Explicit deny policy for client roles. Internal Edge functions use the server role.';
comment on policy bridge_runtime_components_internal_deny
  on public.bridge_runtime_components is
  'Explicit deny policy for client roles. Internal Edge functions use the server role.';

commit;
