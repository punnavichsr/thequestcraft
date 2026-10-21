-- QuestCraft: no two players can have the same name (ItzPxnnz = itzpxnnz = ITZPXNNZ).
-- Run AFTER name_filter.sql. Safe to run again.
--
-- * A NEW player whose name is taken gets a number added (ItzPxnnz -> ItzPxnnz2).
-- * A player who changes to a taken name keeps their old name.
-- * Names that are already the same from before are left alone (fix those by hand).

create or replace function public.leaderboard_unique_name()
returns trigger language plpgsql security definer set search_path = public as $$
declare base text; n int := 1;
begin
  if new.username is null then return new; end if;
  if tg_op = 'UPDATE' and new.username is not distinct from old.username then return new; end if;
  if not exists (select 1 from public.leaderboard
                  where lower(username) = lower(new.username) and user_id is distinct from new.user_id) then
    return new;                                   -- name is free
  end if;
  if tg_op = 'UPDATE' then
    new.username := old.username;                 -- taken: keep the old name
    return new;
  end if;
  -- the game saves with an upsert: if this player already has a row,
  -- the UPDATE part handles the name (keeps their old one), so leave it here
  if exists (select 1 from public.leaderboard where user_id = new.user_id) then return new; end if;
  base := left(new.username, 16);                 -- taken (new player): add a number
  loop
    n := n + 1;
    new.username := base || n;
    exit when not exists (select 1 from public.leaderboard
                           where lower(username) = lower(new.username) and user_id is distinct from new.user_id);
  end loop;
  return new;
end $$;

-- runs after leaderboard_guard (triggers run in name order), so the bad-word filter goes first
drop trigger if exists leaderboard_unique_name on public.leaderboard;
create trigger leaderboard_unique_name
  before insert or update on public.leaderboard
  for each row execute function public.leaderboard_unique_name();

-- Find names used more than once (run on its own):
-- select l.id, l.username, u.email, l.level, l.xp, l.updated_at
-- from public.leaderboard l left join auth.users u on u.id = l.user_id
-- where lower(l.username) in (select lower(username) from public.leaderboard group by 1 having count(*) > 1)
-- order by lower(l.username), l.updated_at;
