-- Low-risk indexes for emergency bridge foreign-key and idempotency lookups.

create index if not exists bridge_route_registry_integration_idx
  on public.bridge_route_registry (integration);

create index if not exists bridge_request_ledger_execution_created_idx
  on public.bridge_request_ledger (user_id, execution_key, created_at desc)
  where execution_key is not null;
