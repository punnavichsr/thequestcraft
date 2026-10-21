-- QuestCraft: the "Ace" title.
-- Finish your Daily Quest 5 days in a row (Thailand time) without EVER cheating
-- -> New Title Unlocked: Ace (shown next to your name on the leaderboard).
-- Run AFTER name_filter.sql and quest_tasks.sql. Safe to run again.
--
-- Cheating = the Auto-Admin catching you finishing tasks too fast, or your XP jumping
-- impossibly fast. One time = no Ace (and you lose it if you already had it).
-- * Bad-name warnings are NOT cheating.
-- * An admin pressing CLEAR on a player gives them their chance back (streak starts again).
-- * Admins are never marked as cheaters (so you can test the warn bot every day).
-- * Everyone starts fresh: cheating from before this file was run doesn't count.

-- 1) Each player's Ace progress (private: only the functions below touch it)
create table if not exists public.ace_progress (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  streak    int not null default 0,       -- Daily Quests finished in a row
  last_day  date,                         -- last day (Thailand time) a Daily Quest was finished
  cheated   boolean not null default false,
  earned_at timestamptz,                  -- when Ace was unlocked
  shown     boolean not null default false -- has the "New Title Unlocked" pop-up been shown?
);
alter table public.ace_progress enable row level security;
revoke all on public.ace_progress from anon, authenticated;

-- 2) The title everyone sees on the leaderboard
alter table public.leaderboard add column if not exists title text;

-- 3) Mark someone as a cheater: no Ace, streak back to 0
create or replace function public.ace_mark_cheat(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null then return; end if;
  insert into public.ace_progress (user_id, cheated) values (p_user, true)
  on conflict (user_id) do update set cheated = true, streak = 0, earned_at = null, shown = false;
end $$;
revoke all on function public.ace_mark_cheat(uuid) from public, anon, authenticated;

-- 4) Count the streak every time a Daily Quest gets finished
create or replace function public.ace_count_streak()
returns trigger language plpgsql security definer set search_path = public as $$
declare d date := (new.completed_at at time zone 'Asia/Bangkok')::date;
begin
  if old.completed_at is null and new.completed_at is not null then
    insert into public.ace_progress (user_id, streak, last_day) values (new.user_id, 1, d)
    on conflict (user_id) do update set
      streak   = case when ace_progress.last_day = d     then ace_progress.streak       -- same day: no change
                      when ace_progress.last_day = d - 1 then ace_progress.streak + 1   -- next day: +1
                      else 1 end,                                                      -- missed a day: start again
      last_day = greatest(coalesce(ace_progress.last_day, d), d);
    -- 5 in a row and never cheated -> Ace unlocked (the pop-up shows when they close the quest)
    update public.ace_progress set earned_at = now()
     where user_id = new.user_id and streak >= 5 and not cheated and earned_at is null;
  end if;
  return new;
end $$;

drop trigger if exists daily_quests_ace_streak on public.daily_quests;
create trigger daily_quests_ace_streak
  after update of completed_at on public.daily_quests
  for each row execute function public.ace_count_streak();

-- 5) Players can't give themselves a title. Also catches the XP-jump cheat and admin CLEAR.
--    (Runs right after leaderboard_guard, because triggers run in name order.)
create or replace function public.leaderboard_title_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare allowed boolean := public.is_questcraft_admin()
                           or coalesce(current_setting('questcraft.ace', true), '') = 'on';
begin
  if tg_op = 'INSERT' then
    if not allowed then
      new.title := (select case when p.earned_at is not null then 'Ace' end
                      from public.ace_progress p where p.user_id = new.user_id);
    end if;
    return new;
  end if;

  if not allowed then new.title := old.title; end if;

  -- XP jumped impossibly fast (same rule as the Auto-Admin) -> cheater, even if the
  -- warning itself was skipped because of the 10-minute rule. Admins are never marked.
  if not public.is_questcraft_admin()
     and coalesce(current_setting('questcraft.auto_admin', true), '') <> 'on'
     and coalesce(new.xp, 0) - coalesce(old.xp, 0) >= 100 and not coalesce(old.banned, false) then
    perform public.ace_mark_cheat(new.user_id);
    if new.title = 'Ace' then new.title := null; end if;
  end if;

  -- an admin pressed CLEAR -> chance back
  if public.is_questcraft_admin() and coalesce(new.cleared, false) and not coalesce(old.cleared, false) then
    update public.ace_progress set cheated = false, streak = 0, last_day = null where user_id = new.user_id;
  end if;
  return new;
end $$;

drop trigger if exists leaderboard_title_guard on public.leaderboard;
create trigger leaderboard_title_guard
  before insert or update on public.leaderboard
  for each row execute function public.leaderboard_title_guard();

-- 6) The quest-too-fast warning (same as auto_admin.sql) + marks the cheater for Ace
create or replace function public.auto_warn_too_fast(seconds numeric, needed numeric)
returns void language plpgsql security definer set search_path = public as $$
declare r public.leaderboard;
begin
  if auth.uid() is null or seconds is null or needed is null or seconds >= needed then
    return;
  end if;

  -- Ace: caught cheating (even if the warning below is skipped). Admins are never marked.
  if not public.is_questcraft_admin() then
    perform public.ace_mark_cheat(auth.uid());
    perform set_config('questcraft.ace', 'on', true);
    update public.leaderboard set title = null where user_id = auth.uid() and title = 'Ace';
    perform set_config('questcraft.ace', 'off', true);
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

-- 7) The game calls this when you close the Daily Quest.
--    Unlocks Ace if you've earned it, and says "show the pop-up" exactly once.
create or replace function public.ace_check()
returns json language plpgsql security definer set search_path = public as $$
declare p public.ace_progress; today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if auth.uid() is null then return json_build_object('streak', 0); end if;
  select * into p from public.ace_progress where user_id = auth.uid();
  if not found then return json_build_object('streak', 0); end if;

  if p.earned_at is null and p.streak >= 5 and not p.cheated then
    update public.ace_progress set earned_at = now() where user_id = auth.uid() returning * into p;
  end if;

  if p.earned_at is not null then
    perform set_config('questcraft.ace', 'on', true);
    update public.leaderboard set title = 'Ace' where user_id = auth.uid() and title is distinct from 'Ace';
    perform set_config('questcraft.ace', 'off', true);
    if not p.shown then
      update public.ace_progress set shown = true where user_id = auth.uid();
      return json_build_object('new_title', 'Ace', 'streak', p.streak);
    end if;
  end if;

  return json_build_object(
    'streak', case when p.last_day >= today - 1 then p.streak else 0 end,
    'title',  case when p.earned_at is not null then 'Ace' end);
end $$;

revoke all on function public.ace_check() from public, anon;
grant execute on function public.ace_check() to authenticated;
