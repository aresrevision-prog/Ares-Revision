-- Ares Revision — events + ping-everyone. Run once in the Supabase SQL editor.
-- (needs is_current_user_admin() and current_username() from the main migration)
create table if not exists events (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('ping','event')),
  title text not null,
  message text not null default '',
  starts_at timestamptz,
  active boolean not null default true,
  created_by text not null,
  created_at timestamptz not null default now()
);
alter table events enable row level security;
drop policy if exists "anyone reads active events" on events;
create policy "anyone reads active events" on events
  for select to anon using (active = true or is_current_user_admin());
drop policy if exists "admin inserts events" on events;
create policy "admin inserts events" on events
  for insert to anon with check (is_current_user_admin());
drop policy if exists "admin updates events" on events;
create policy "admin updates events" on events
  for update to anon using (is_current_user_admin()) with check (is_current_user_admin());
grant select, insert, update on events to anon;
grant usage, select on sequence events_id_seq to anon;
