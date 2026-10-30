-- QuestCraft: game-wide settings, the same for every player.
-- First one: score_rules = how Timer minutes turn into stat points.
-- Everyone can read them; only admins can change them (through Jarvis -> set_game_setting).
-- Run in Supabase: SQL Editor -> paste -> Run. Safe to run again.

create table if not exists public.game_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.game_settings enable row level security;
drop policy if exists "game_settings: anyone can read" on public.game_settings;
create policy "game_settings: anyone can read" on public.game_settings for select using (true);
-- no insert/update/delete policies: changes only go through set_game_setting()

create or replace function public.set_game_setting(p_key text, p_value jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_questcraft_admin() then
    raise exception 'Only admins can change game settings';
  end if;
  if p_key = 'score_rules' and (
       jsonb_typeof(p_value -> 'modes') is distinct from 'object'
       or coalesce((p_value ->> 'minutes_per_point')::int, 0) not between 1 and 600) then
    raise exception 'score_rules needs "modes" (an object) and "minutes_per_point" (1 to 600)';
  end if;
  insert into game_settings (key, value, updated_at) values (p_key, p_value, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return p_value;
end $$;

revoke all on function public.set_game_setting(text, jsonb) from public, anon;
grant execute on function public.set_game_setting(text, jsonb) to authenticated;

-- default: every 60 min on the Timer = +1 point; study -> IQ, exercise -> Strength, sleep -> Sleep; gaming earns nothing
insert into public.game_settings (key, value)
values ('score_rules', '{"minutes_per_point": 60, "modes": {"IQ": "IQ", "Strength": "Strength", "Sleep": "Sleep"}}')
on conflict (key) do nothing;
