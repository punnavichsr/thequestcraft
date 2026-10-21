-- QuestCraft: show each player's class on the leaderboard.
-- Run once in Supabase: SQL Editor -> paste -> Run. Safe to run again.
-- (Classes are just for looks, so players are allowed to set their own.)

alter table public.leaderboard
  add column if not exists hero_class text;

-- everyone who hasn't played since this update is a Warrior (that's what Knights became)
update public.leaderboard set hero_class = 'warrior' where hero_class is null;
alter table public.leaderboard alter column hero_class set default 'warrior';

-- only real class names, so nobody can put junk text there
alter table public.leaderboard drop constraint if exists leaderboard_hero_class_check;
alter table public.leaderboard add constraint leaderboard_hero_class_check
  check (hero_class is null or hero_class in ('warrior', 'assassin', 'mage', 'archer'));
