-- Cover the bridge route -> control foreign key used by the route resolver.
-- This is additive, non-destructive, and directly addresses the Supabase
-- unindexed-foreign-key advisor finding for requires_control_key.

create index if not exists bridge_route_registry_requires_control_key_idx
  on public.bridge_route_registry (requires_control_key)
  where requires_control_key is not null;
