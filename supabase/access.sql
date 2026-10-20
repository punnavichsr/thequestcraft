-- QuestCraft: early-access lock (promo codes, VIP accounts, future paid plans).
-- Run AFTER appeals_email.sql. Safe to run again.
-- Promo codes live ONLY in the database (the GitHub repo is public).

-- 1) Promo codes. The countdown starts when an admin presses START.
create table if not exists public.promo_codes (
  code       text primary key,
  duration   interval not null default interval '1 month',
  started_at timestamptz,
  ends_at    timestamptz,          -- null = countdown not started yet
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.promo_codes enable row level security;   -- no policies: only the functions below read it
revoke all on public.promo_codes from anon, authenticated;

insert into public.promo_codes (code) values ('53743') on conflict (code) do nothing;

-- 2) Who may play. kind: 'vip' (forever), 'promo' (ends with its code), 'paid' (ends at expires_at)
create table if not exists public.access_grants (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('vip', 'promo', 'paid')),
  code       text references public.promo_codes(code),
  expires_at timestamptz,          -- used for 'paid'
  granted_at timestamptz not null default now()
);
alter table public.access_grants enable row level security;
revoke all on public.access_grants from anon, authenticated;

-- the account that owns the hero "ATOMic"
insert into public.access_grants (user_id, kind)
values ('489843a9-4d6d-4c9c-83e1-1f0a82397571', 'vip')
on conflict (user_id) do update set kind = 'vip', code = null, expires_at = null;

-- 3) What is my access right now?
-- status: ok | none | plan_expired | subscription_ended
create or replace function public.my_access()
returns json language plpgsql stable security definer set search_path = public as $$
declare g public.access_grants; p public.promo_codes;
begin
  if auth.uid() is null then return json_build_object('status', 'none'); end if;
  if public.is_questcraft_admin() then return json_build_object('status', 'ok', 'kind', 'admin'); end if;
  select * into g from public.access_grants where user_id = auth.uid();
  if not found then return json_build_object('status', 'none'); end if;
  if g.kind = 'vip' then return json_build_object('status', 'ok', 'kind', 'vip'); end if;
  if g.kind = 'paid' then
    if g.expires_at is not null and g.expires_at <= now() then
      return json_build_object('status', 'subscription_ended', 'kind', 'paid', 'ends_at', g.expires_at);
    end if;
    return json_build_object('status', 'ok', 'kind', 'paid', 'ends_at', g.expires_at);
  end if;
  -- promo
  select * into p from public.promo_codes where code = g.code;
  if not found or not p.active or (p.ends_at is not null and p.ends_at <= now()) then
    return json_build_object('status', 'plan_expired', 'kind', 'promo', 'ends_at', p.ends_at);
  end if;
  return json_build_object('status', 'ok', 'kind', 'promo', 'ends_at', p.ends_at);
end $$;

create or replace function public.has_access()
returns boolean language sql stable security definer set search_path = public as $$
  select (public.my_access() ->> 'status') = 'ok'
$$;

-- 4) Enter a promo code
create or replace function public.redeem_code(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare p public.promo_codes; g public.access_grants;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  select * into p from public.promo_codes where code = trim(p_code);
  if not found or not p.active then raise exception 'That code is not valid.'; end if;
  if p.ends_at is not null and p.ends_at <= now() then raise exception 'That code has expired.'; end if;
  select * into g from public.access_grants where user_id = auth.uid();
  if found and g.kind in ('vip', 'paid') then return public.my_access(); end if;   -- never downgrade
  insert into public.access_grants (user_id, kind, code) values (auth.uid(), 'promo', p.code)
  on conflict (user_id) do update set kind = 'promo', code = excluded.code, granted_at = now();
  return public.my_access();
end $$;

-- 5) Admin: see codes + START the countdown
create or replace function public.admin_promo_codes()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_questcraft_admin() then raise exception 'admins only'; end if;
  return coalesce((select json_agg(json_build_object(
            'code', c.code, 'duration', c.duration::text, 'started_at', c.started_at, 'ends_at', c.ends_at,
            'active', c.active,
            'players', (select count(*) from public.access_grants g where g.code = c.code))
          order by c.created_at) from public.promo_codes c), '[]'::json);
end $$;

create or replace function public.admin_start_promo(p_code text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.is_questcraft_admin() then raise exception 'admins only'; end if;
  update public.promo_codes set started_at = now(), ends_at = now() + duration
  where code = p_code and started_at is null;
  if not found then raise exception 'Code not found or its countdown already started.'; end if;
  return public.admin_promo_codes();
end $$;

revoke all on function public.my_access(), public.has_access(), public.redeem_code(text),
  public.admin_promo_codes(), public.admin_start_promo(text) from public, anon;
grant execute on function public.my_access(), public.has_access(), public.redeem_code(text),
  public.admin_promo_codes(), public.admin_start_promo(text) to authenticated;

-- 6) Only players with access can save scores
drop policy if exists "leaderboard: add your own row"    on public.leaderboard;
drop policy if exists "leaderboard: update your own row" on public.leaderboard;
create policy "leaderboard: add your own row"
  on public.leaderboard for insert to authenticated
  with check (user_id = auth.uid() and public.has_access());
create policy "leaderboard: update your own row"
  on public.leaderboard for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and public.has_access());
