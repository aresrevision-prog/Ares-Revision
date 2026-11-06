-- Ares Revision — game codes (Frontline Warzone). Run once in the Supabase SQL editor.
-- (needs is_current_user_admin() from the main migration, same as schema_events.sql)
create table if not exists game_codes (
  code text primary key check (code = lower(code) and length(code) between 2 and 24),
  reward text not null check (reward in ('honors','coins','skin')),
  amount int not null default 0,
  skin text,
  expires_at timestamptz,
  active boolean not null default true,
  created_by text not null,
  created_at timestamptz not null default now()
);
alter table game_codes enable row level security;
drop policy if exists "anyone reads live codes" on game_codes;
create policy "anyone reads live codes" on game_codes
  for select to anon using ((active and (expires_at is null or expires_at > now())) or is_current_user_admin());
drop policy if exists "admin inserts codes" on game_codes;
create policy "admin inserts codes" on game_codes for insert to anon with check (is_current_user_admin());
drop policy if exists "admin updates codes" on game_codes;
create policy "admin updates codes" on game_codes for update to anon using (is_current_user_admin()) with check (is_current_user_admin());
drop policy if exists "admin deletes codes" on game_codes;
create policy "admin deletes codes" on game_codes for delete to anon using (is_current_user_admin());
grant select, insert, update, delete on game_codes to anon;
