-- `CREATE OR REPLACE VIEW` cannot insert a column before existing columns.
-- Drop the internal service-role-only view immediately before migration 805
-- recreates it with the additive security backlog field. The migration runner
-- executes the migration transactionally; no anon/authenticated grant exists.

drop view if exists public.bridge_readiness_snapshot;
