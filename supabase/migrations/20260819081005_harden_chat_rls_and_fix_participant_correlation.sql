-- Fix a correlated-policy bug and reduce excessive grants on the currently empty
-- chat prototype tables. This is isolated from the emergency bridge tables.

create or replace function public.is_current_user_thread_participant(p_thread_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
set row_security = off
as $$
  select exists(
    select 1
    from public.thread_participants tp
    where tp.thread_id = p_thread_id
      and tp.user_id = (select auth.uid())
  );
$$;

create or replace function public.is_current_user_thread_creator(p_thread_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
set row_security = off
as $$
  select exists(
    select 1
    from public.threadsddd t
    where t.id = p_thread_id
      and t.created_by = (select auth.uid())
  );
$$;

revoke all on function public.is_current_user_thread_participant(uuid)
  from public, anon;
revoke all on function public.is_current_user_thread_creator(uuid)
  from public, anon;
grant execute on function public.is_current_user_thread_participant(uuid)
  to authenticated;
grant execute on function public.is_current_user_thread_creator(uuid)
  to authenticated;

revoke all on table public.threadsddd from anon, authenticated;
revoke all on table public.thread_participants from anon, authenticated;
revoke all on table public.messages from anon, authenticated;

grant select, insert, update, delete on table public.threadsddd
  to authenticated;
grant select, insert, delete on table public.thread_participants
  to authenticated;
grant select, insert on table public.messages
  to authenticated;

drop policy if exists threads_select_participant on public.threadsddd;
drop policy if exists threads_insert_creator on public.threadsddd;
drop policy if exists threads_update_creator on public.threadsddd;
drop policy if exists threads_delete_creator on public.threadsddd;

create policy threads_select_participant
on public.threadsddd
for select
to authenticated
using (public.is_current_user_thread_participant(id));

create policy threads_insert_creator
on public.threadsddd
for insert
to authenticated
with check (created_by = (select auth.uid()));

create policy threads_update_creator
on public.threadsddd
for update
to authenticated
using (created_by = (select auth.uid()))
with check (created_by = (select auth.uid()));

create policy threads_delete_creator
on public.threadsddd
for delete
to authenticated
using (created_by = (select auth.uid()));

drop policy if exists participants_select_in_my_threads on public.thread_participants;
drop policy if exists participants_insert_by_creator on public.thread_participants;
drop policy if exists participants_delete_by_creator on public.thread_participants;

create policy participants_select_in_my_threads
on public.thread_participants
for select
to authenticated
using (
  public.is_current_user_thread_participant(thread_id)
  or public.is_current_user_thread_creator(thread_id)
);

create policy participants_insert_by_creator
on public.thread_participants
for insert
to authenticated
with check (public.is_current_user_thread_creator(thread_id));

create policy participants_delete_by_creator
on public.thread_participants
for delete
to authenticated
using (public.is_current_user_thread_creator(thread_id));

drop policy if exists messages_select_participant on public.messages;
drop policy if exists messages_insert_sender_participant on public.messages;

create policy messages_select_participant
on public.messages
for select
to authenticated
using (public.is_current_user_thread_participant(thread_id));

create policy messages_insert_sender_participant
on public.messages
for insert
to authenticated
with check (
  sender_id = (select auth.uid())
  and public.is_current_user_thread_participant(thread_id)
);

comment on function public.is_current_user_thread_participant(uuid) is
  'Returns whether auth.uid() participates in the given thread. SECURITY DEFINER avoids recursive RLS evaluation and exposes no row data.';
comment on function public.is_current_user_thread_creator(uuid) is
  'Returns whether auth.uid() created the given thread. SECURITY DEFINER avoids recursive RLS evaluation and exposes no row data.';
