-- QuestCraft: XP per task (no Complete button). Ticks are saved in the database.
-- Run AFTER temp_ban.sql. Safe to run again.

alter table public.daily_quests add column if not exists done int[] not null default '{}';

create or replace function public.daily_quest_state(q public.daily_quests)
returns json language sql stable as $$
  select json_build_object(
    'started_at',   q.started_at,
    'ends_at',      q.started_at + interval '24 hours',
    'tasks',        q.tasks,
    'done',         q.done,
    'xp_per_task',  5,
    'completed',    q.completed_at is not null,
    'completed_at', q.completed_at,
    'server_now',   now())
$$;

-- new quests start with nothing ticked
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
    return public.daily_quest_state(q);
  end if;
  how_many := 3 + floor(random() * 3)::int;
  for i in 1..how_many loop
    select sum(p.weight) into total from public.quest_task_pool() p where not (p.name = any(picked));
    r := random() * total; acc := 0;
    for t in select p.name, p.weight from public.quest_task_pool() p where not (p.name = any(picked)) loop
      acc := acc + t.weight;
      if r < acc then picked := picked || t.name; exit; end if;
    end loop;
  end loop;
  insert into public.daily_quests (user_id, started_at, tasks, completed_at, done)
  values (auth.uid(), now(), picked, null, '{}')
  on conflict (user_id) do update set started_at = now(), tasks = excluded.tasks, completed_at = null, done = '{}'
  returning * into q;
  return public.daily_quest_state(q);
end $$;

-- Tick / untick one task. Returns the quest + how much XP to add (+5) or take back (-5).
create or replace function public.set_quest_task(p_index int, p_done boolean)
returns json language plpgsql security definer set search_path = public as $$
declare q public.daily_quests; was boolean; delta int := 0; elapsed numeric; needed numeric; too_fast boolean := false;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not public.has_access() then raise exception 'No access.'; end if;
  select * into q from public.daily_quests where user_id = auth.uid() for update;
  if not found then raise exception 'Open your Daily Quest first.'; end if;
  if q.started_at <= now() - interval '24 hours' then raise exception 'This Daily Quest ran out of time. Open QUEST again for a new one.'; end if;
  if p_index < 0 or p_index >= coalesce(array_length(q.tasks, 1), 0) then raise exception 'Unknown task.'; end if;

  was := p_index = any(q.done);
  if p_done and not was then
    q.done := q.done || p_index; delta := 5;
  elsif not p_done and was then
    q.done := array_remove(q.done, p_index); delta := -5;
  end if;

  update public.daily_quests
     set done = q.done,
         completed_at = case when cardinality(q.done) = cardinality(q.tasks) then coalesce(completed_at, now()) else null end
   where user_id = auth.uid()
  returning * into q;

  -- speed check on every new tick: time since the quest was first opened (time away counts)
  if delta > 0 then
    elapsed := extract(epoch from now() - q.started_at);
    select coalesce(sum(p.min_seconds), 0) into needed
      from public.quest_task_pool() p
     where p.name = any(array(select q.tasks[i + 1] from unnest(q.done) as i));
    too_fast := elapsed < needed;
    if too_fast then perform public.auto_warn_too_fast(elapsed, needed); end if;
  end if;

  return (public.daily_quest_state(q)::jsonb || jsonb_build_object('xp_delta', delta, 'too_fast', too_fast))::json;
end $$;

revoke all on function public.set_quest_task(int, boolean) from public, anon;
grant execute on function public.set_quest_task(int, boolean) to authenticated;
