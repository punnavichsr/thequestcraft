-- QuestCraft: Auto-Admin (WARN only), XP reset, ban email.
-- Run AFTER leaderboard_admin.sql and warn_email.sql. Safe to run again.

alter table public.leaderboard
  add column if not exists warned_by    text,          -- 'admin' or 'auto'
  add column if not exists xp_reset_at  timestamptz,   -- set by an admin's RESET XP
  add column if not exists xp_reset_ack timestamptz;   -- the player's game has applied that reset

-- Players can't change their own moderation fields.
-- The Auto-Admin function below is the only exception (it sets a private flag).
create or replace function public.leaderboard_guard()
returns trigger language plpgsql as $$
declare
  auto_admin boolean := coalesce(current_setting('questcraft.auto_admin', true), '') = 'on';
begin
  if not public.is_questcraft_admin() and not auto_admin then
    if tg_op = 'UPDATE' then
      new.user_id      := old.user_id;
      new.banned       := old.banned;
      new.warned       := old.warned;
      new.warned_at    := old.warned_at;
      new.warn_message := old.warn_message;
      new.warned_by    := old.warned_by;
      new.cleared      := old.cleared;
      new.warn_count   := old.warn_count;
      new.cleared_xp   := old.cleared_xp;
      new.xp_reset_at  := old.xp_reset_at;
      -- after an XP reset, ignore scores from a game that hasn't applied the reset yet
      if old.xp_reset_at is not null and new.xp_reset_ack is distinct from old.xp_reset_at then
        new.xp    := old.xp;
        new.level := old.level;
      end if;
      -- backup rule: a single jump of 100+ XP is impossible for an honest player
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
  new.updated_at := now();
  return new;
end $$;

-- Called by the game when a quest is finished faster than its tasks could take.
create or replace function public.auto_warn_too_fast(seconds numeric, needed numeric)
returns void language plpgsql security definer set search_path = public as $$
declare r public.leaderboard;
begin
  if auth.uid() is null or seconds is null or needed is null or seconds >= needed then
    return;
  end if;
  select * into r from public.leaderboard where user_id = auth.uid();
  if not found or r.banned then return; end if;
  -- don't pile up warnings (and emails): at most one auto-warning per 10 minutes
  if r.warned_at is not null and r.warned_at > now() - interval '10 minutes' then return; end if;

  perform set_config('questcraft.auto_admin', 'on', true);
  update public.leaderboard set
    warned       = true,
    warned_at    = now(),
    warned_by    = 'auto',
    warn_count   = r.warn_count + 1,
    warn_message = case when r.warn_count >= 1
      then format('LAST WARNING: you finished a quest in %s seconds, but those tasks take at least %s. One more time and your account will be terminated.', round(seconds), round(needed))
      else format('The Auto-Admin noticed you finished a quest in %s seconds, but those tasks take at least %s. Please really do your tasks!', round(seconds), round(needed)) end
  where id = r.id;
  perform set_config('questcraft.auto_admin', 'off', true);
end $$;

revoke all on function public.auto_warn_too_fast(numeric, numeric) from public, anon;
grant execute on function public.auto_warn_too_fast(numeric, numeric) to authenticated;

-- Email the admins on every warning (now says who gave it).
create or replace function public.email_admins_on_warning()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  api_key text;
  who     text := replace(replace(coalesce(new.username, 'A player'), '<', '&lt;'), '>', '&gt;');
  label   text := case when new.warn_count >= 2 then 'LAST WARNING' else 'Warning' end;
  giver   text := case when new.warned_by = 'auto' then '🤖 Auto-Admin' else 'an Admin' end;
begin
  if coalesce(new.warn_count, 0) <= coalesce(old.warn_count, 0) then return new; end if;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if api_key is null then return new; end if;
  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'from',    'QuestCraft <noreply@thequestcraft.com>',
      'to',      jsonb_build_array('ss53753@samsenwit.ac.th', 'punnavich.sr@gmail.com'),
      'subject', format('⚠️ QuestCraft: %s got a %s', coalesce(new.username, 'a player'), label),
      'html',    format(
        '<h2>⚠️ %s given by %s</h2><p><b>%s</b> received warning #%s.</p>'
        '<p>Message shown to them: <i>%s</i></p>'
        '<p>XP: <b>%s</b> · Level: <b>%s</b> · Time: %s (Bangkok)</p>'
        '<p>Open <a href="https://thequestcraft.com">thequestcraft.com</a> → Leaderboard to follow up.</p>',
        label, giver, who, new.warn_count,
        replace(replace(coalesce(new.warn_message, ''), '<', '&lt;'), '>', '&gt;'),
        coalesce(new.xp, 0), coalesce(new.level, 1),
        to_char(now() at time zone 'Asia/Bangkok', 'DD Mon YYYY HH24:MI'))));
  return new;
end $$;

-- Email the PLAYER when they get banned.
create or replace function public.email_player_on_ban()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  api_key text;
  player_email text;
  who text := replace(replace(coalesce(new.username, 'Adventurer'), '<', '&lt;'), '>', '&gt;');
begin
  if not (coalesce(new.banned, false) and not coalesce(old.banned, false)) then return new; end if;
  select email into player_email from auth.users where id = new.user_id;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if api_key is null or player_email is null then return new; end if;
  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'from',     'QuestCraft <noreply@thequestcraft.com>',
      'to',       jsonb_build_array(player_email),
      'reply_to', 'support@thequestcraft.com',
      'subject',  'Your QuestCraft account has been terminated',
      'html',     format(
        '<h2>⛔ Account Terminated</h2>'
        '<p>Hi %s,</p>'
        '<p>Your QuestCraft account has been terminated for breaking the fair-play rules.</p>'
        '<p>If you think this is a mistake, contact support at '
        '<a href="mailto:support@thequestcraft.com">support@thequestcraft.com</a> to get your account back.</p>'
        '<p>— The QuestCraft Team</p>', who)));
  return new;
end $$;

drop trigger if exists leaderboard_ban_email on public.leaderboard;
create trigger leaderboard_ban_email
  after update on public.leaderboard
  for each row execute function public.email_player_on_ban();
