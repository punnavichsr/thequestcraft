-- QuestCraft: bad-word name filter, run by the Auto-Admin (the 24/7 warn bot).
-- Run AFTER temp_ban.sql. Safe to run again.
--
-- What it does:
--   * A player tries to save a name with a bad word -> the name is NOT saved
--     (they keep their old name, or "Unnamed"), and the Auto-Admin gives 1 warning.
--   * Trying the same bad name again doesn't warn again (the game re-saves often).
--     A NEW bad name = a new warning. The 3rd warning = the usual 30-minute ban.
--   * Admins are never filtered.
--   * Add or remove words any time: Table Editor -> bad_words. No code needed.
--     anywhere = true  -> caught even inside other letters ("xXfuckXx")
--     anywhere = false -> only caught as a whole word (so "Classic" is fine but "ass" isn't)

-- 1) Remember the last bad name each player tried (so the same one only warns once)
alter table public.leaderboard
  add column if not exists blocked_name text;

-- 2) The bad-word list (private: only the functions below read it)
create table if not exists public.bad_words (
  word     text primary key,
  anywhere boolean not null default false
);
alter table public.bad_words enable row level security;
revoke all on public.bad_words from anon, authenticated;

insert into public.bad_words (word, anywhere) values
  -- English, caught anywhere (no normal name contains these)
  ('fuck', true), ('shit', true), ('bitch', true), ('cunt', true), ('asshole', true),
  ('nigger', true), ('nigga', true), ('faggot', true), ('whore', true), ('slut', true),
  ('pussy', true), ('penis', true), ('vagina', true), ('porn', true), ('hitler', true),
  ('bastard', true), ('retard', true), ('motherf', true), ('wtf', true), ('stfu', true),
  -- English, whole word only (these hide inside normal words: Classic, Grape, Dickens, Sussex...)
  ('ass', false), ('dick', false), ('cock', false), ('fag', false), ('rape', false),
  ('sex', false), ('cum', false), ('hoe', false), ('tits', false), ('nazi', false),
  ('kys', false), ('damn', false),
  -- Thai, caught anywhere
  ('ควย', true), ('เหี้ย', true), ('เหี่ย', true), ('เย็ด', true), ('แตด', true),
  ('สัส', true), ('ระยำ', true), ('จัญไร', true), ('อีดอก', true), ('ส้นตีน', true),
  -- Thai, whole name only (part of normal words, e.g. หีบ = box)
  ('หี', false)
on conflict (word) do nothing;

-- 3) Does this text contain a bad word?
--    Undoes tricks like f.u.c.k, F_U_C_K, fuuuck, sh1t, $hit, @ss
create or replace function public.has_bad_word(t text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  s text; spaced text; squashed text; short text;
begin
  if t is null or btrim(t) = '' then return false; end if;
  s := lower(t);
  s := translate(s, '013457@$!|', 'oieastasii');            -- 0->o 1->i 3->e 4->a 5->s 7->t @->a $->s
  spaced   := btrim(regexp_replace(s, '[^a-z0-9ก-๛]+', ' ', 'g'));
  squashed := replace(spaced, ' ', '');
  short    := regexp_replace(squashed, '(.)\1+', '\1', 'g');  -- fuuuuck -> fuck
  return exists (
    select 1 from public.bad_words w
    where (w.anywhere and (position(lower(w.word) in squashed) > 0
                           or position(regexp_replace(lower(w.word), '(.)\1+', '\1', 'g') in short) > 0))
       or (not w.anywhere and (' ' || spaced || ' ') like ('% ' || lower(w.word) || ' %'))
  );
end $$;

revoke all on function public.has_bad_word(text) from public, anon;
grant execute on function public.has_bad_word(text) to authenticated;

-- 4) The guard (latest version from temp_ban.sql) + the name filter
create or replace function public.leaderboard_guard()
returns trigger language plpgsql as $$
declare
  auto_admin boolean := coalesce(current_setting('questcraft.auto_admin', true), '') = 'on';
  name_msg   text    := 'The Auto-Admin blocked your name because it has a bad word in it. Please pick a clean name.';
  last_msg   text    := 'LAST WARNING: you tried to use a name with a bad word again. One more time and your account will be terminated.';
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
      new.blocked_name     := old.blocked_name;
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

      -- NAME FILTER: a new name with a bad word is not saved
      if new.username is distinct from old.username and public.has_bad_word(new.username) then
        if new.username is distinct from old.blocked_name and not old.banned then
          new.warned       := true;
          new.warned_at    := now();
          new.warned_by    := 'auto';
          new.warn_count   := coalesce(new.warn_count, 0) + 1;
          new.warn_message := case when new.warn_count >= 2 then last_msg else name_msg end;
        end if;
        new.blocked_name := new.username;
        new.username     := case when public.has_bad_word(old.username) then 'Unnamed' else old.username end;
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
      new.blocked_name     := null;

      -- NAME FILTER for brand-new players
      -- (the game saves with an upsert: if this player already has a row, the
      --  UPDATE part below handles the name, so leave the name alone here)
      if public.has_bad_word(new.username)
         and not exists (select 1 from public.leaderboard where user_id = auth.uid()) then
        new.blocked_name := new.username;
        new.username     := 'Unnamed';
        new.warned       := true;
        new.warned_at    := now();
        new.warned_by    := 'auto';
        new.warn_count   := 1;
        new.warn_message := name_msg;
      end if;
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

-- 5) Admins: find names that were saved BEFORE this filter existed
--    (run this line on its own in the SQL Editor)
-- select id, username from public.leaderboard where public.has_bad_word(username);
