-- Refresh the public PR #5 gate hourly without storing a GitHub token.

create extension if not exists pg_cron with schema extensions;

select cron.unschedule(jobid)
from cron.job
where jobname='refresh-github-pr5-gate';

select cron.schedule(
  'refresh-github-pr5-gate',
  '37 * * * *',
  $$select public.refresh_github_pr5_gate();$$
);
