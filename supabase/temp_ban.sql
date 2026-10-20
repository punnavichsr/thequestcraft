-- QuestCraft: 3rd warning = automatic 30-minute ban, only once per account.
-- After that one time, further warnings don't auto-ban (an admin decides).
-- Run AFTER daily_quest.sql. Safe to run again.

alter table public.leaderboard
  add column if not exists banned_until     timestamptz,
  add column if not exists temp_banned_once boolean not null default false;

-- guard (latest version) + protect the new columns + the 3-warning rule
create or replace function public.leaderboard_guard()
returns trigger language plpgsql as $$
declare
  auto_admin boolean := coalesce(current_setting('questcraft.auto_admin', true), '') = 'on';
begin
  if not public.is_questcraft_admin() and not auto_admin then
    if tg_op = 'UPDATE' then
      new.user_id          := old.user_id;
      new.banned           := old.banned;
      new.perma_banned     := old.perma_banned;
      new.warned           := old.warned;
      new.warned_at        := old.warned_at;
      new.warn_message     := old.warn_message;
      new.warned_by        := old.warned_by;
      new.cleared          := old.cleared;
      new.warn_count       := old.warn_count;
      new.cleared_xp       := old.cleared_xp;
      new.xp_reset_at      := old.xp_reset_at;
      new.banned_until     := old.banned_until;
      new.temp_banned_once := old.temp_banned_once;
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
      new.user_id          := auth.uid();
      new.banned           := false;
      new.perma_banned     := false;
      new.warned           := false;
      new.warned_at        := null;
      new.warn_message     := null;
      new.warned_by        := null;
      new.cleared          := false;
      new.warn_count       := 0;
      new.cleared_xp       := null;
      new.xp_reset_at      := null;
      new.banned_until     := null;
      new.temp_banned_once := false;
    end if;
  end if;

  -- 3rd warning (from anyone): the bot bans for 30 minutes, only the first time
  if tg_op = 'UPDATE' and coalesce(new.warn_count, 0) >= 3 and coalesce(old.warn_count, 0) < 3
     and not coalesce(old.temp_banned_once, false) and not coalesce(new.banned, false) then
    new.banned_until     := now() + interval '30 minutes';
    new.temp_banned_once := true;
    new.warn_message     := coalesce(new.warn_message, '') ||
                            ' This is your 3rd warning, so the Auto-Admin has banned you for 30 minutes.';
  end if;

  if new.perma_banned then new.banned := true; end if;
  new.updated_at := now();
  return new;
end $$;

-- access now also reports a temporary ban
create or replace function public.my_access()
returns json language plpgsql stable security definer set search_path = public as $$
declare g public.access_grants; p public.promo_codes; until timestamptz;
begin
  if auth.uid() is null then return json_build_object('status', 'none'); end if;
  if public.is_questcraft_admin() then return json_build_object('status', 'ok', 'kind', 'admin'); end if;
  select banned_until into until from public.leaderboard where user_id = auth.uid();
  if until is not null and until > now() then
    return json_build_object('status', 'temp_banned', 'until', until, 'server_now', now());
  end if;
  select * into g from public.access_grants where user_id = auth.uid();
  if not found then return json_build_object('status', 'none'); end if;
  if g.kind = 'vip' then return json_build_object('status', 'ok', 'kind', 'vip'); end if;
  if g.kind = 'paid' then
    if g.expires_at is not null and g.expires_at <= now() then
      return json_build_object('status', 'subscription_ended', 'kind', 'paid', 'ends_at', g.expires_at);
    end if;
    return json_build_object('status', 'ok', 'kind', 'paid', 'ends_at', g.expires_at);
  end if;
  select * into p from public.promo_codes where code = g.code;
  if not found or not p.active or (p.ends_at is not null and p.ends_at <= now()) then
    return json_build_object('status', 'plan_expired', 'kind', 'promo', 'ends_at', p.ends_at);
  end if;
  return json_build_object('status', 'ok', 'kind', 'promo', 'ends_at', p.ends_at);
end $$;

-- admin email mentions the 30-minute ban when it happens
create or replace function public.email_admins_on_warning()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  api_key text;
  who     text := replace(replace(coalesce(new.username, 'A player'), '<', '&lt;'), '>', '&gt;');
  label   text := case when new.warn_count >= 2 then 'LAST WARNING' else 'Warning' end;
  giver   text := case when new.warned_by = 'auto' then '🤖 Auto-Admin' else 'an Admin' end;
  tempban text := case when new.temp_banned_once and not coalesce(old.temp_banned_once, false)
                       then '<p><b>⏳ 3rd warning: the Auto-Admin banned them for 30 minutes (one time only).</b></p>' else '' end;
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
        '<h2>⚠️ %s given by %s</h2><p><b>%s</b> received warning #%s.</p>%s'
        '<p>Message shown to them: <i>%s</i></p>'
        '<p>XP: <b>%s</b> · Level: <b>%s</b> · Time: %s (Bangkok)</p>'
        '<p>Open <a href="https://thequestcraft.com">thequestcraft.com</a> → Leaderboard to follow up.</p>',
        label, giver, who, new.warn_count, tempban,
        replace(replace(coalesce(new.warn_message, ''), '<', '&lt;'), '>', '&gt;'),
        coalesce(new.xp, 0), coalesce(new.level, 1),
        to_char(now() at time zone 'Asia/Bangkok', 'DD Mon YYYY HH24:MI'))));
  return new;
end $$;
