-- QuestCraft: no false "too fast" warning for the tutorial.
-- In the tutorial, new players tick a Daily Quest task right away to learn how it works.
-- Each account gets ONE free fast tick (the first one): no warning, no Ace cheat mark.
-- Every tick after that is speed-checked exactly like before.
-- Run AFTER quest_tasks.sql. Safe to run again.

create table if not exists public.tutorial_free_tick (
  user_id uuid primary key references auth.users(id) on delete cascade,
  used_at timestamptz not null default now()
);
alter table public.tutorial_free_tick enable row level security;   -- no policies: only the function below touches it

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
    -- the tutorial's tick: the first fast tick of an account is free (once only)
    if too_fast and not exists (select 1 from public.tutorial_free_tick where user_id = auth.uid()) then
      insert into public.tutorial_free_tick (user_id) values (auth.uid());
      too_fast := false;
    end if;
    if too_fast then perform public.auto_warn_too_fast(elapsed, needed); end if;
  end if;

  return (public.daily_quest_state(q)::jsonb || jsonb_build_object('xp_delta', delta, 'too_fast', too_fast))::json;
end $$;
