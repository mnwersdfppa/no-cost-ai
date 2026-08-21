-- The following migration adds a column in the middle of the readiness view.
-- PostgreSQL cannot reorder existing view columns with CREATE OR REPLACE VIEW.
-- Drop only this derived view immediately before rebuilding it; all underlying
-- tables, evidence and credentials remain unchanged.

drop view if exists public.bridge_readiness_snapshot;
