-- QuestCraft: email the admins every time a player is warned.
-- Needs a Vault secret named 'resend_api_key' (Project Settings -> Vault).
-- Run in Supabase: SQL Editor -> paste -> Run. Safe to run again.

create extension if not exists pg_net with schema extensions;

create or replace function public.email_admins_on_warning()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  api_key text;
  who     text := replace(replace(coalesce(new.username, 'A player'), '<', '&lt;'), '>', '&gt;');
  label   text := case when new.warn_count >= 2 then 'LAST WARNING' else 'Warning' end;
begin
  if coalesce(new.warn_count, 0) <= coalesce(old.warn_count, 0) then
    return new;   -- not a new warning
  end if;

  select decrypted_secret into api_key
  from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if api_key is null then
    return new;   -- no key saved yet: skip the email, never block the warning
  end if;

  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
                 'Authorization', 'Bearer ' || api_key,
                 'Content-Type',  'application/json'),
    body    := jsonb_build_object(
                 'from',    'QuestCraft <noreply@thequestcraft.com>',
                 'to',      jsonb_build_array('ss53753@samsenwit.ac.th', 'punnavich.sr@gmail.com'),
                 'subject', format('⚠️ QuestCraft: %s got a %s', coalesce(new.username, 'a player'), label),
                 'html',    format(
                   '<h2>⚠️ %s given</h2>'
                   '<p><b>%s</b> received warning #%s.</p>'
                   '<p>XP: <b>%s</b> · Level: <b>%s</b></p>'
                   '<p>Time: %s</p>'
                   '<p>Open <a href="https://thequestcraft.com">thequestcraft.com</a> → Leaderboard to follow up.</p>',
                   label, who, new.warn_count, coalesce(new.xp, 0), coalesce(new.level, 1),
                   to_char(now() at time zone 'Asia/Bangkok', 'DD Mon YYYY HH24:MI') || ' (Bangkok)')
               )
  );
  return new;
end $$;

drop trigger if exists leaderboard_warn_email on public.leaderboard;
create trigger leaderboard_warn_email
  after update on public.leaderboard
  for each row execute function public.email_admins_on_warning();
