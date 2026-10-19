-- QuestCraft: warning history + ban appeals (approve / decline forever).
-- Run AFTER auto_admin.sql. Safe to run again.

-- 1) Permanent ban flag
alter table public.leaderboard
  add column if not exists perma_banned boolean not null default false;

-- guard again, now also protecting perma_banned
create or replace function public.leaderboard_guard()
returns trigger language plpgsql as $$
declare
  auto_admin boolean := coalesce(current_setting('questcraft.auto_admin', true), '') = 'on';
begin
  if not public.is_questcraft_admin() and not auto_admin then
    if tg_op = 'UPDATE' then
      new.user_id      := old.user_id;
      new.banned       := old.banned;
      new.perma_banned := old.perma_banned;
      new.warned       := old.warned;
      new.warned_at    := old.warned_at;
      new.warn_message := old.warn_message;
      new.warned_by    := old.warned_by;
      new.cleared      := old.cleared;
      new.warn_count   := old.warn_count;
      new.cleared_xp   := old.cleared_xp;
      new.xp_reset_at  := old.xp_reset_at;
      if old.xp_reset_at is not null and new.xp_reset_ack is distinct from old.xp_reset_at then
        new.xp    := old.xp;
        new.level := old.level;
      end if;
      if coalesce(new.xp, 0) - coalesce(old.xp, 0) >= 100 and not old.banned
         and (old.warned_at is null or old.warned_at < now() - interval '10 minutes') then
        new.warned       := true;
        new.warned_at    := now();
        new.warned_by    := 'auto';
        new.warn_count   := old.warn_count + 1;
        new.warn_message := case when old.warn_count >= 1
          then 'LAST WARNING: your XP jumped impossibly fast again. One more time and your account will be terminated.'
          else 'The Auto-Admin noticed your XP jumped impossibly fast. Please play fair, or your account may be banned.' end;
      end if;
    else
      new.user_id      := auth.uid();
      new.banned       := false;
      new.perma_banned := false;
      new.warned       := false;
      new.warned_at    := null;
      new.warn_message := null;
      new.warned_by    := null;
      new.cleared      := false;
      new.warn_count   := 0;
      new.cleared_xp   := null;
      new.xp_reset_at  := null;
    end if;
  end if;
  -- a permanently banned account always stays banned
  if new.perma_banned then new.banned := true; end if;
  new.updated_at := now();
  return new;
end $$;

-- 2) Warning history (one row per warning, written by the database)
create table if not exists public.warning_log (
  id             bigint generated always as identity primary key,
  leaderboard_id bigint references public.leaderboard(id) on delete cascade,
  user_id        uuid,
  warn_number    int,
  warned_by      text,
  reason         text,
  created_at     timestamptz not null default now()
);
alter table public.warning_log enable row level security;
drop policy if exists "warning_log: admins and owner read" on public.warning_log;
create policy "warning_log: admins and owner read" on public.warning_log
  for select to authenticated using (public.is_questcraft_admin() or user_id = auth.uid());

create or replace function public.log_warning()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.warn_count, 0) > coalesce(old.warn_count, 0) then
    insert into public.warning_log (leaderboard_id, user_id, warn_number, warned_by, reason)
    values (new.id, new.user_id, new.warn_count, coalesce(new.warned_by, 'admin'), new.warn_message);
  end if;
  return new;
end $$;
drop trigger if exists leaderboard_log_warning on public.leaderboard;
create trigger leaderboard_log_warning after update on public.leaderboard
  for each row execute function public.log_warning();

-- 3) Appeals
create table if not exists public.appeals (
  id             bigint generated always as identity primary key,
  user_id        uuid not null default auth.uid(),
  leaderboard_id bigint references public.leaderboard(id) on delete cascade,
  message        text not null check (char_length(message) between 1 and 1000),
  status         text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  created_at     timestamptz not null default now(),
  decided_at     timestamptz
);
alter table public.appeals enable row level security;

drop policy if exists "appeals: banned player can ask once at a time" on public.appeals;
drop policy if exists "appeals: admins and owner read"               on public.appeals;
create policy "appeals: banned player can ask once at a time" on public.appeals
  for insert to authenticated
  with check (
    user_id = auth.uid() and status = 'pending'
    and exists (select 1 from public.leaderboard l
                where l.id = leaderboard_id and l.user_id = auth.uid()
                  and l.banned and not l.perma_banned)
    and not exists (select 1 from public.appeals a
                    where a.user_id = auth.uid() and a.status = 'pending'));
create policy "appeals: admins and owner read" on public.appeals
  for select to authenticated using (public.is_questcraft_admin() or user_id = auth.uid());
-- (no update policy: decisions only go through decide_appeal below)

create or replace function public.decide_appeal(appeal_id bigint, approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare a public.appeals;
begin
  if not public.is_questcraft_admin() then raise exception 'admins only'; end if;
  select * into a from public.appeals where id = appeal_id and status = 'pending';
  if not found then raise exception 'appeal not found or already decided'; end if;
  update public.appeals set status = case when approve then 'approved' else 'declined' end,
                            decided_at = now() where id = appeal_id;
  if approve then
    update public.leaderboard set banned = false, perma_banned = false, warned = false, cleared = true
    where id = a.leaderboard_id;
  else
    update public.leaderboard set banned = true, perma_banned = true where id = a.leaderboard_id;
  end if;
end $$;
revoke all on function public.decide_appeal(bigint, boolean) from public, anon;
grant execute on function public.decide_appeal(bigint, boolean) to authenticated;

-- 4) Emails
-- a) new appeal -> both admins, with the full warning history
create or replace function public.email_admins_on_appeal()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  api_key text; l public.leaderboard; history text;
  esc text;
begin
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if api_key is null then return new; end if;
  select * into l from public.leaderboard where id = new.leaderboard_id;
  select coalesce(string_agg(format('<li><b>Warning #%s</b> · %s · by %s<br><i>%s</i></li>',
           w.warn_number, to_char(w.created_at at time zone 'Asia/Bangkok', 'DD Mon YYYY HH24:MI'),
           case when w.warned_by = 'auto' then '🤖 Auto-Admin' else 'Admin' end,
           replace(replace(coalesce(w.reason, ''), '<', '&lt;'), '>', '&gt;')), '' order by w.created_at),
           '<li>No warnings on record.</li>')
    into history from public.warning_log w where w.leaderboard_id = new.leaderboard_id;
  esc := replace(replace(new.message, '<', '&lt;'), '>', '&gt;');
  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'from',    'QuestCraft <noreply@thequestcraft.com>',
      'to',      jsonb_build_array('ss53753@samsenwit.ac.th', 'punnavich.sr@gmail.com'),
      'subject', format('📨 Ban appeal from %s', coalesce(l.username, 'a player')),
      'html',    format(
        '<h2>📨 New ban appeal</h2><p><b>%s</b> (XP %s, Level %s) asks for their account back:</p>'
        '<blockquote>%s</blockquote><h3>Warning history</h3><ul>%s</ul>'
        '<p>To <b>approve</b> or <b>decline</b>: open <a href="https://thequestcraft.com">thequestcraft.com</a>, '
        'sign in, start the game and open <b>📨 APPEALS</b>. Declining terminates the account forever.</p>',
        replace(replace(coalesce(l.username, 'Player'), '<', '&lt;'), '>', '&gt;'),
        coalesce(l.xp, 0), coalesce(l.level, 1), esc, history)));
  return new;
end $$;
drop trigger if exists appeals_email_admins on public.appeals;
create trigger appeals_email_admins after insert on public.appeals
  for each row execute function public.email_admins_on_appeal();

-- b) decision -> the player
create or replace function public.email_player_on_decision()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare api_key text; player_email text;
begin
  if new.status = old.status or new.status = 'pending' then return new; end if;
  select email into player_email from auth.users where id = new.user_id;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if api_key is null or player_email is null then return new; end if;
  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'from',    'QuestCraft <noreply@thequestcraft.com>',
      'to',      jsonb_build_array(player_email),
      'subject', case when new.status = 'approved' then '✅ Your QuestCraft account is back'
                      else '⛔ Your QuestCraft appeal was declined' end,
      'html',    case when new.status = 'approved'
        then '<h2>✅ Appeal approved</h2><p>Your QuestCraft account has been restored. Please play fair! '
             '<a href="https://thequestcraft.com">Play now</a></p>'
        else '<h2>⛔ Appeal declined</h2><p>Your appeal was reviewed and declined. '
             'This QuestCraft account is permanently terminated and can no longer be used.</p>' end));
  return new;
end $$;
drop trigger if exists appeals_email_player on public.appeals;
create trigger appeals_email_player after update on public.appeals
  for each row execute function public.email_player_on_decision();

-- c) ban email now points to the in-game appeal
create or replace function public.email_player_on_ban()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  api_key text; player_email text;
  who text := replace(replace(coalesce(new.username, 'Adventurer'), '<', '&lt;'), '>', '&gt;');
begin
  if not (coalesce(new.banned, false) and not coalesce(old.banned, false)) then return new; end if;
  if new.perma_banned then return new; end if;   -- the decline email already covers this
  select email into player_email from auth.users where id = new.user_id;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if api_key is null or player_email is null then return new; end if;
  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'from',    'QuestCraft <noreply@thequestcraft.com>',
      'to',      jsonb_build_array(player_email),
      'subject', 'Your QuestCraft account has been terminated',
      'html',    format(
        '<h2>⛔ Account Terminated</h2><p>Hi %s,</p>'
        '<p>Your QuestCraft account has been terminated for breaking the fair-play rules.</p>'
        '<p>If you think this is a mistake, contact support: open '
        '<a href="https://thequestcraft.com">thequestcraft.com</a>, sign in, and tap <b>REQUEST APPEAL</b>. '
        'You can send one appeal at a time.</p><p>— The QuestCraft Team</p>', who)));
  return new;
end $$;
