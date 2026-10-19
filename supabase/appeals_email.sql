-- QuestCraft: decide appeals from the email (secret link -> thequestcraft.com/appeal.html).
-- Run AFTER appeals.sql. Safe to run again.

-- Secret codes for the email links. RLS on + no policies = nobody can read them through the API.
create table if not exists public.appeal_tokens (
  appeal_id  bigint primary key references public.appeals(id) on delete cascade,
  token      uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now()
);
alter table public.appeal_tokens enable row level security;
revoke all on public.appeal_tokens from anon, authenticated;

-- New appeal -> secret link -> email both admins
create or replace function public.email_admins_on_appeal()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  api_key text; l public.leaderboard; history text; tok uuid; link text;
begin
  insert into public.appeal_tokens (appeal_id) values (new.id)
  on conflict (appeal_id) do nothing;
  select token into tok from public.appeal_tokens where appeal_id = new.id;
  link := format('https://thequestcraft.com/appeal.html?id=%s&token=%s', new.id, tok);

  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if api_key is null then return new; end if;
  select * into l from public.leaderboard where id = new.leaderboard_id;
  select coalesce(string_agg(format('<li><b>Warning #%s</b> · %s · by %s<br><i>%s</i></li>',
           w.warn_number, to_char(w.created_at at time zone 'Asia/Bangkok', 'DD Mon YYYY HH24:MI'),
           case when w.warned_by = 'auto' then '🤖 Auto-Admin' else 'Admin' end,
           replace(replace(coalesce(w.reason, ''), '<', '&lt;'), '>', '&gt;')), '' order by w.created_at),
           '<li>No warnings on record.</li>')
    into history from public.warning_log w where w.leaderboard_id = new.leaderboard_id;

  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'from',    'QuestCraft <noreply@thequestcraft.com>',
      'to',      jsonb_build_array('ss53753@samsenwit.ac.th', 'punnavich.sr@gmail.com'),
      'subject', format('📨 Ban appeal from %s', coalesce(l.username, 'a player')),
      'html',    format(
        '<h2>📨 New ban appeal</h2><p><b>%s</b> (XP %s, Level %s) asks for their account back:</p>'
        '<blockquote style="border-left:3px solid #5EC8FF;padding-left:10px">%s</blockquote>'
        '<h3>Warning history</h3><ul>%s</ul>'
        '<p><a href="%s" style="display:inline-block;background:#5EC8FF;color:#031B1F;padding:12px 18px;'
        'text-decoration:none;font-weight:bold">Review appeal: Approve or Decline</a></p>'
        '<p style="color:#888;font-size:12px">This link is secret: don''t forward it. It stops working after you decide or after 14 days. '
        'Declining terminates the account forever.</p>',
        replace(replace(coalesce(l.username, 'Player'), '<', '&lt;'), '>', '&gt;'),
        coalesce(l.xp, 0), coalesce(l.level, 1),
        replace(replace(new.message, '<', '&lt;'), '>', '&gt;'), history, link)));
  return new;
end $$;

-- The review page reads an appeal with its secret code
create or replace function public.get_appeal_by_token(p_id bigint, p_token uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare a public.appeals; l public.leaderboard;
begin
  if not exists (select 1 from public.appeal_tokens t
                 where t.appeal_id = p_id and t.token = p_token
                   and t.created_at > now() - interval '14 days') then
    return json_build_object('error', 'This link is not valid or has expired.');
  end if;
  select * into a from public.appeals where id = p_id;
  select * into l from public.leaderboard where id = a.leaderboard_id;
  return json_build_object(
    'player',  coalesce(l.username, 'Player'),
    'xp',      coalesce(l.xp, 0),
    'level',   coalesce(l.level, 1),
    'message', a.message,
    'status',  a.status,
    'sent_at', a.created_at,
    'history', coalesce((select json_agg(json_build_object(
                  'n', w.warn_number, 'at', w.created_at, 'by', w.warned_by, 'reason', w.reason)
                  order by w.created_at)
                from public.warning_log w where w.leaderboard_id = a.leaderboard_id), '[]'::json));
end $$;

-- The review page's Approve / Decline buttons
create or replace function public.decide_appeal_by_token(p_id bigint, p_token uuid, approve boolean)
returns text language plpgsql security definer set search_path = public as $$
declare a public.appeals;
begin
  if not exists (select 1 from public.appeal_tokens t
                 where t.appeal_id = p_id and t.token = p_token
                   and t.created_at > now() - interval '14 days') then
    raise exception 'This link is not valid or has expired.';
  end if;
  select * into a from public.appeals where id = p_id;
  if a.status <> 'pending' then
    raise exception 'This appeal was already %.', a.status;
  end if;

  update public.appeals set status = case when approve then 'approved' else 'declined' end,
                            decided_at = now() where id = p_id;
  perform set_config('questcraft.auto_admin', 'on', true);   -- let this function change ban fields
  if approve then
    update public.leaderboard set banned = false, perma_banned = false, warned = false, cleared = true
    where id = a.leaderboard_id;
  else
    update public.leaderboard set banned = true, perma_banned = true where id = a.leaderboard_id;
  end if;
  perform set_config('questcraft.auto_admin', 'off', true);
  return case when approve then 'approved' else 'declined' end;
end $$;

revoke all on function public.get_appeal_by_token(bigint, uuid) from public;
revoke all on function public.decide_appeal_by_token(bigint, uuid, boolean) from public;
grant execute on function public.get_appeal_by_token(bigint, uuid) to anon, authenticated;
grant execute on function public.decide_appeal_by_token(bigint, uuid, boolean) to anon, authenticated;
