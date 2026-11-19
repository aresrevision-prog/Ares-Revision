-- Frontlines Warfare accounts (username + password, cloud save), linkable to a MagicWinter account.
-- Run once in Supabase -> SQL Editor -> New query -> paste -> Run,
-- in the same project that holds MagicWinter accounts (run magicwinter-accounts.sql and magicwinter-links.sql first).
-- Passwords are stored only as bcrypt hashes. Tables are locked: the game can only call the functions below.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.fl_accounts (
  username      text primary key check (username ~ '^[a-z0-9][a-z0-9_]{2,19}$'),
  display_name  text not null,
  pass_hash     text not null,
  save          jsonb,
  saved_at      timestamptz,
  created_at    timestamptz not null default now(),
  failed        int not null default 0,
  locked_until  timestamptz
);
create table if not exists public.fl_sessions (
  token       text primary key,
  username    text not null references public.fl_accounts(username) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null
);
create table if not exists public.fl_signups (at timestamptz not null default now());
alter table public.fl_accounts enable row level security;
alter table public.fl_sessions enable row level security;
alter table public.fl_signups enable row level security;
revoke all on public.fl_accounts, public.fl_sessions, public.fl_signups from anon, authenticated;

-- let the MagicWinter linked-accounts table hold Frontlines links too
alter table public.mw_links drop constraint if exists mw_links_kind_check;
alter table public.mw_links add constraint mw_links_kind_check check (kind in ('ares', 'cipher', 'frontlines'));

create or replace function public.fl__session(u text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  delete from fl_sessions where expires_at < now();
  insert into fl_sessions(token, username, expires_at) values (t, u, now() + interval '60 days');
  return t;
end $$;

create or replace function public.fl__user(p_token text) returns text
language sql stable security definer set search_path = public as $$
  select username from fl_sessions where token = p_token and expires_at > now()
$$;

create or replace function public.fl__mw(u text) returns text
language sql stable security definer set search_path = public as $$
  select a.display_name from mw_links l join mw_accounts a on a.username = l.mw_username
  where l.kind = 'frontlines' and l.ext_id = u limit 1
$$;

create or replace function public.fl__check(u text, p text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a fl_accounts;
begin
  select * into a from fl_accounts where username = u;
  if not found then perform pg_sleep(0.3); return json_build_object('error', 'Wrong username or password.'); end if;
  if a.locked_until is not null and a.locked_until > now() then
    return json_build_object('error', 'Too many tries — wait a minute and try again.'); end if;
  if extensions.crypt(coalesce(p, ''), a.pass_hash) <> a.pass_hash then
    update fl_accounts set locked_until = case when failed + 1 >= 5 then now() + interval '1 minute' else null end,
      failed = case when failed + 1 >= 5 then 0 else failed + 1 end where username = u;
    return json_build_object('error', 'Wrong username or password.');
  end if;
  update fl_accounts set failed = 0, locked_until = null where username = u;
  return json_build_object('ok', true);
end $$;

create or replace function public.fl_signup(p_username text, p_password text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u text := lower(trim(coalesce(p_username, '')));
begin
  if u !~ '^[a-z0-9][a-z0-9_]{2,19}$' then
    return json_build_object('error', 'Usernames are 3–20 letters, numbers or _ (start with a letter or number).'); end if;
  if length(coalesce(p_password, '')) < 6 or length(p_password) > 200 then
    return json_build_object('error', 'Passwords need at least 6 characters.'); end if;
  if (select count(*) from fl_signups where at > now() - interval '1 hour') >= 200 then
    return json_build_object('error', 'Lots of new accounts right now — try again in a bit.'); end if;
  if exists (select 1 from fl_accounts where username = u) then
    return json_build_object('error', 'That username is taken.'); end if;
  delete from fl_signups where at < now() - interval '1 day';
  insert into fl_signups default values;
  insert into fl_accounts(username, display_name, pass_hash) values (u, left(trim(p_username), 20), extensions.crypt(p_password, extensions.gen_salt('bf', 10)));
  return json_build_object('ok', true, 'username', left(trim(p_username), 20), 'token', fl__session(u), 'save', null, 'mw', null);
end $$;

create or replace function public.fl_login(p_username text, p_password text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u text := lower(trim(coalesce(p_username, ''))); r json := fl__check(u, p_password); a fl_accounts;
begin
  if (r->>'ok') is null then return r; end if;
  select * into a from fl_accounts where username = u;
  return json_build_object('ok', true, 'username', a.display_name, 'token', fl__session(u), 'save', a.save, 'saved_at', a.saved_at, 'mw', fl__mw(u));
end $$;

create or replace function public.fl_load(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare u text := fl__user(p_token); a fl_accounts;
begin
  if u is null then return json_build_object('error', 'signed out'); end if;
  select * into a from fl_accounts where username = u;
  return json_build_object('ok', true, 'username', a.display_name, 'save', a.save, 'saved_at', a.saved_at, 'mw', fl__mw(u));
end $$;

create or replace function public.fl_save(p_token text, p_save jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare u text := fl__user(p_token);
begin
  if u is null then return json_build_object('error', 'signed out'); end if;
  if p_save is null or jsonb_typeof(p_save) <> 'object' or length(p_save::text) > 300000 then
    return json_build_object('error', 'Save is too big.'); end if;
  update fl_accounts set save = p_save, saved_at = now() where username = u;
  return json_build_object('ok', true, 'saved_at', now());
end $$;

create or replace function public.fl_logout(p_token text) returns json
language plpgsql security definer set search_path = public as $$
begin
  delete from fl_sessions where token = p_token;
  return json_build_object('ok', true);
end $$;

-- link this Frontlines account to a MagicWinter account (needs a MagicWinter session token from mw_login)
create or replace function public.fl_link_mw(p_token text, p_mw_token text) returns json
language plpgsql security definer set search_path = public as $$
declare u text := fl__user(p_token); m text := mw__user(p_mw_token);
begin
  if u is null then return json_build_object('error', 'Please sign in to Frontlines again.'); end if;
  if m is null then return json_build_object('error', 'MagicWinter sign-in didn''t go through. Try again.'); end if;
  if exists (select 1 from mw_links where kind = 'frontlines' and ext_id = u and mw_username <> m) then
    return json_build_object('error', 'This Frontlines account is already linked to a different MagicWinter account.'); end if;
  delete from mw_links where mw_username = m and kind = 'frontlines';
  insert into mw_links (mw_username, kind, ext_id, ext_name) values (m, 'frontlines', u, (select display_name from fl_accounts where username = u))
  on conflict (kind, ext_id) do update set ext_name = excluded.ext_name, linked_at = now();
  return json_build_object('ok', true, 'mw', fl__mw(u));
end $$;

create or replace function public.fl_unlink_mw(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare u text := fl__user(p_token);
begin
  if u is null then return json_build_object('error', 'Please sign in again.'); end if;
  delete from mw_links where kind = 'frontlines' and ext_id = u;
  return json_build_object('ok', true);
end $$;

-- sign in to Frontlines with a MagicWinter account: uses the linked Frontlines account,
-- or makes one (same name as the MagicWinter account when it's free) and links it.
create or replace function public.fl_login_mw(p_mw_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare m text := mw__user(p_mw_token); u text; nm text; base text; i int := 0; a fl_accounts;
begin
  if m is null then return json_build_object('error', 'MagicWinter sign-in didn''t go through. Try again.'); end if;
  select ext_id into u from mw_links where kind = 'frontlines' and mw_username = m;
  if u is null or not exists (select 1 from fl_accounts where username = u) then
    select display_name into nm from mw_accounts where username = m;
    base := left(m, 17); u := base;
    while exists (select 1 from fl_accounts where username = u) loop i := i + 1; u := base || i; end loop;
    insert into fl_accounts(username, display_name, pass_hash)
      values (u, coalesce(nm, m), extensions.crypt(encode(extensions.gen_random_bytes(18), 'hex'), extensions.gen_salt('bf', 10)));
    delete from mw_links where mw_username = m and kind = 'frontlines';
    insert into mw_links (mw_username, kind, ext_id, ext_name) values (m, 'frontlines', u, coalesce(nm, m));
  end if;
  select * into a from fl_accounts where username = u;
  return json_build_object('ok', true, 'username', a.display_name, 'token', fl__session(u), 'save', a.save, 'saved_at', a.saved_at, 'mw', fl__mw(u));
end $$;

-- link from the MagicWinter site: MagicWinter session + Frontlines username/password
create or replace function public.mw_link_frontlines(p_token text, p_fl_user text, p_fl_pass text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare m text := mw__user(p_token); u text := lower(trim(coalesce(p_fl_user, ''))); r json;
begin
  if m is null then return json_build_object('error', 'Please sign in to MagicWinter again.'); end if;
  r := fl__check(u, p_fl_pass);
  if (r->>'ok') is null then return r; end if;
  if exists (select 1 from mw_links where kind = 'frontlines' and ext_id = u and mw_username <> m) then
    return json_build_object('error', 'That Frontlines account is already linked to a different MagicWinter account.'); end if;
  delete from mw_links where mw_username = m and kind = 'frontlines';
  insert into mw_links (mw_username, kind, ext_id, ext_name) values (m, 'frontlines', u, (select display_name from fl_accounts where username = u))
  on conflict (kind, ext_id) do update set ext_name = excluded.ext_name, linked_at = now();
  return json_build_object('ok', true, 'kind', 'frontlines', 'ext_id', u, 'ext_name', (select display_name from fl_accounts where username = u));
end $$;

revoke all on function public.fl__session(text), public.fl__user(text), public.fl__mw(text), public.fl__check(text, text) from public, anon, authenticated;
revoke all on function public.fl_signup(text, text), public.fl_login(text, text), public.fl_load(text), public.fl_save(text, jsonb), public.fl_logout(text),
  public.fl_link_mw(text, text), public.fl_unlink_mw(text), public.fl_login_mw(text), public.mw_link_frontlines(text, text, text) from public;
grant execute on function public.fl_signup(text, text), public.fl_login(text, text), public.fl_load(text), public.fl_save(text, jsonb), public.fl_logout(text),
  public.fl_link_mw(text, text), public.fl_unlink_mw(text), public.fl_login_mw(text), public.mw_link_frontlines(text, text, text) to anon, authenticated;
