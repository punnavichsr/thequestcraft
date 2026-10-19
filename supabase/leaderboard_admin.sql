-- QuestCraft: make the leaderboard work + admin tools (warn / ban / clear)
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to run again.

-- 1) New columns
alter table public.leaderboard
  add column if not exists user_id uuid references auth.users(id) on delete cascade,
  add column if not exists warned boolean not null default false,
  add column if not exists warned_at timestamptz,
  add column if not exists warn_message text,
  add column if not exists cleared boolean not null default false,
  add column if not exists updated_at timestamptz not null default now();

alter table public.leaderboard alter column banned set default false;
update public.leaderboard set banned = false where banned is null;

-- one leaderboard row per account
create unique index if not exists leaderboard_user_id_key on public.leaderboard(user_id);

-- 2) Who is the admin? (checked by the database, not the webpage)
create or replace function public.is_questcraft_admin()
returns boolean language sql stable as $$
  select coalesce(auth.jwt() ->> 'email', '') = 'punnavich.sr@gmail.com'
$$;

-- 3) Players can never change their own warn/ban/clear status
create or replace function public.leaderboard_guard()
returns trigger language plpgsql as $$
begin
  if not public.is_questcraft_admin() then
    if tg_op = 'UPDATE' then
      new.user_id      := old.user_id;
      new.banned       := old.banned;
      new.warned       := old.warned;
      new.warned_at    := old.warned_at;
      new.warn_message := old.warn_message;
      new.cleared      := old.cleared;
    else
      new.user_id      := auth.uid();
      new.banned       := false;
      new.warned       := false;
      new.warned_at    := null;
      new.warn_message := null;
      new.cleared      := false;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists leaderboard_guard on public.leaderboard;
create trigger leaderboard_guard
  before insert or update on public.leaderboard
  for each row execute function public.leaderboard_guard();

-- 4) Rules (RLS policies)
alter table public.leaderboard enable row level security;

drop policy if exists "leaderboard: anyone can read"        on public.leaderboard;
drop policy if exists "leaderboard: add your own row"       on public.leaderboard;
drop policy if exists "leaderboard: update your own row"    on public.leaderboard;
drop policy if exists "leaderboard: admin can update any"   on public.leaderboard;

create policy "leaderboard: anyone can read"
  on public.leaderboard for select using (true);

create policy "leaderboard: add your own row"
  on public.leaderboard for insert to authenticated
  with check (user_id = auth.uid());

create policy "leaderboard: update your own row"
  on public.leaderboard for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "leaderboard: admin can update any"
  on public.leaderboard for update to authenticated
  using (public.is_questcraft_admin()) with check (true);
