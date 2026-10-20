-- QuestCraft: AI memory for signed-in players (each player sees only their own).
-- Run AFTER quest_tasks.sql. Safe to run again.

create table if not exists public.ai_memory (
  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  notes      text[] not null default '{}',     -- things the AI was asked to remember
  history    jsonb  not null default '[]',     -- the last messages of the chat
  updated_at timestamptz not null default now()
);
alter table public.ai_memory enable row level security;

drop policy if exists "ai_memory: read your own"   on public.ai_memory;
drop policy if exists "ai_memory: add your own"    on public.ai_memory;
drop policy if exists "ai_memory: change your own" on public.ai_memory;
drop policy if exists "ai_memory: clear your own"  on public.ai_memory;
create policy "ai_memory: read your own"   on public.ai_memory for select to authenticated using (user_id = auth.uid());
create policy "ai_memory: add your own"    on public.ai_memory for insert to authenticated with check (user_id = auth.uid());
create policy "ai_memory: change your own" on public.ai_memory for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "ai_memory: clear your own"  on public.ai_memory for delete to authenticated using (user_id = auth.uid());

-- keep it small: at most 40 notes of 200 characters, at most 40 messages
create or replace function public.ai_notes_ok(n text[])
returns boolean language sql immutable as $$
  select coalesce(bool_and(char_length(x) <= 200), true) from unnest(n) as x
$$;
alter table public.ai_memory drop constraint if exists ai_memory_size;
alter table public.ai_memory add constraint ai_memory_size check (
  cardinality(notes) <= 40 and jsonb_array_length(history) <= 40 and public.ai_notes_ok(notes));
