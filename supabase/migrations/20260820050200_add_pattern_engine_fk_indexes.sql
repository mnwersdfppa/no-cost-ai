-- Pattern Promotion Engine v1: foreign-key lookup indexes.
-- Applied to Supabase project dpllasnpfskyyyzebyal after performance advisor review.

create index if not exists openclaw_pattern_feedback_pattern_key_idx
  on public.openclaw_pattern_feedback(pattern_key, created_at desc);

create index if not exists openclaw_pattern_promotion_log_pattern_key_idx
  on public.openclaw_pattern_promotion_log(pattern_key, created_at desc);

create index if not exists openclaw_pattern_evidence_links_pattern_key_idx
  on public.openclaw_pattern_evidence_links(pattern_key, observed_at desc);

create index if not exists openclaw_skill_versions_pattern_key_idx
  on public.openclaw_skill_versions(pattern_key, skill_version desc);
