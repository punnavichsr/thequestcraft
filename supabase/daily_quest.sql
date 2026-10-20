-- QuestCraft: Daily Quest with a 24-hour countdown kept by the database.
-- The server picks the tasks and keeps the clock, so changing time zones, clearing the
-- browser, or reopening the quest can't reset it or re-roll the tasks.
-- Run AFTER access.sql. Safe to run again.

create table if not exists public.daily_quests (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  started_at   timestamptz not null,
  tasks        text[] not null,
  completed_at timestamptz
);
alter table public.daily_quests enable row level security;   -- only the functions below touch it
revoke all on public.daily_quests from anon, authenticated;

-- The task pool: chance per pick (adds up to 100) and the fastest honest time in seconds.
-- Hobby and Preread are the special (gold) ones at 15% each; the other three are 23.333% each.
create or replace function public.quest_task_pool()
returns table(name text, weight numeric, min_seconds int) language sql immutable as $$
  values ('Do all your homework',               23.333::numeric,  30),
         ('Study for your Exams or Quizzes',    23.333::numeric,  60),
         ('Read 1 book and Summarize',          23.334::numeric, 120),
         ('Do your favorite hobby or exercise', 15::numeric,      60),
         ('Preread (Random Chance)',            15::numeric,      60)
$$;

create or replace function public.daily_quest_state(q public.daily_quests)
returns json language sql stable as $$
  select json_build_object(
    'started_at', q.started_at,
    'ends_at',    q.started_at + interval '24 hours',
    'tasks',      q.tasks,
    'completed',  q.completed_at is not null,
    'completed_at', q.completed_at,
    'server_now', now())
$$;

-- Open the quest: returns today's quest, or starts a new 24-hour one.
create or replace function public.start_daily_quest()
returns json language plpgsql security definer set search_path = public as $$
declare
  q public.daily_quests;
  how_many int; picked text[] := '{}'; total numeric; r numeric; acc numeric; t record;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not public.has_access() then raise exception 'No access.'; end if;

  select * into q from public.daily_quests where user_id = auth.uid();
  if found and q.started_at > now() - interval '24 hours' then
    return public.daily_quest_state(q);                      -- same quest until the 24 hours are up
  end if;

  -- pick 3-5 different tasks, each pick weighted by the chances above
  how_many := 3 + floor(random() * 3)::int;
  for i in 1..how_many loop
    select sum(p.weight) into total from public.quest_task_pool() p where not (p.name = any(picked));
    r := random() * total; acc := 0;
    for t in select p.name, p.weight from public.quest_task_pool() p where not (p.name = any(picked)) loop
      acc := acc + t.weight;
      if r < acc then picked := picked || t.name; exit; end if;
    end loop;
  end loop;

  insert into public.daily_quests (user_id, started_at, tasks, completed_at)
  values (auth.uid(), now(), picked, null)
  on conflict (user_id) do update set started_at = now(), tasks = excluded.tasks, completed_at = null
  returning * into q;
  return public.daily_quest_state(q);
end $$;

-- Finish the quest: only once per 24 hours. Too fast = automatic warning.
create or replace function public.complete_daily_quest()
returns json language plpgsql security definer set search_path = public as $$
declare q public.daily_quests; elapsed numeric; needed numeric; too_fast boolean;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  select * into q from public.daily_quests where user_id = auth.uid();
  if not found then raise exception 'Open your Daily Quest first.'; end if;
  if q.started_at <= now() - interval '24 hours' then raise exception 'This Daily Quest ran out of time. Open a new one.'; end if;
  if q.completed_at is not null then raise exception 'You already finished today''s Daily Quest.'; end if;

  elapsed := extract(epoch from now() - q.started_at);
  select coalesce(sum(p.min_seconds), 0) into needed from public.quest_task_pool() p where p.name = any(q.tasks);
  too_fast := elapsed < needed;

  update public.daily_quests set completed_at = now() where user_id = auth.uid() returning * into q;
  if too_fast then perform public.auto_warn_too_fast(elapsed, needed); end if;

  return (public.daily_quest_state(q)::jsonb
          || jsonb_build_object('xp', coalesce(array_length(q.tasks, 1), 0) * 5, 'too_fast', too_fast))::json;
end $$;

revoke all on function public.start_daily_quest(), public.complete_daily_quest() from public, anon;
grant execute on function public.start_daily_quest(), public.complete_daily_quest() to authenticated;
