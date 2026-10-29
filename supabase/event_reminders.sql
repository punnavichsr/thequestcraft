-- QuestCraft: email players a reminder before their timetable events.
-- The game sends the list of upcoming events (set_my_reminders), and a job
-- that runs every minute emails the ones that are due (send_due_reminders).
-- Emails only ever go to the player's own sign-in email.
-- Needs the Vault secret 'resend_api_key' (same one the warning emails use).
-- Run in Supabase: SQL Editor -> paste -> Run. Safe to run again.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create table if not exists public.event_reminders (
  id         bigserial primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title      text not null,
  when_label text,
  remind_at  timestamptz not null,
  sent_at    timestamptz
);
create index if not exists event_reminders_due on public.event_reminders (remind_at) where sent_at is null;

alter table public.event_reminders enable row level security;
drop policy if exists "see my reminders" on public.event_reminders;
create policy "see my reminders" on public.event_reminders
  for select using (user_id = auth.uid());
-- no insert/update/delete policies: changes only go through set_my_reminders()

-- Replace all of my not-yet-sent reminders with this list.
-- items = [{"title":"...", "when_label":"Thu 30 Oct · 15:00", "remind_at":"2026-10-30T07:45:00Z"}, ...]
-- An empty list turns reminders off.
create or replace function public.set_my_reminders(items jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  n   int;
begin
  if uid is null then
    raise exception 'Sign in first';
  end if;

  delete from event_reminders where user_id = uid and sent_at is null;

  insert into event_reminders (user_id, title, when_label, remind_at)
  select uid, left(x.title, 120), left(x.when_label, 60), x.remind_at
  from jsonb_to_recordset(coalesce(items, '[]'::jsonb)) as x(title text, when_label text, remind_at timestamptz)
  where coalesce(trim(x.title), '') <> ''
    and x.remind_at > now()
    and x.remind_at < now() + interval '15 days'
  order by x.remind_at
  limit 60;   -- keeps the email count (and Resend's free limit) in check

  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.set_my_reminders(jsonb) from public, anon;
grant execute on function public.set_my_reminders(jsonb) to authenticated;

-- Runs every minute: emails every reminder that is due.
create or replace function public.send_due_reminders()
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  api_key text;
  r       record;
  sent    int := 0;
  safe    text;
begin
  select decrypted_secret into api_key
  from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if api_key is null then
    return 0;
  end if;

  -- too late to be useful (e.g. the job was paused): drop them quietly
  update event_reminders set sent_at = now()
  where sent_at is null and remind_at < now() - interval '30 minutes';

  for r in
    select er.id, er.title, er.when_label, u.email
    from event_reminders er
    join auth.users u on u.id = er.user_id
    where er.sent_at is null and er.remind_at <= now() and u.email is not null
    order by er.remind_at
    limit 50
    for update of er skip locked
  loop
    safe := replace(replace(replace(r.title, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    perform net.http_post(
      url     := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
                   'Authorization', 'Bearer ' || api_key,
                   'Content-Type',  'application/json'),
      body    := jsonb_build_object(
                   'from',    'QuestCraft <noreply@thequestcraft.com>',
                   'to',      jsonb_build_array(r.email),
                   'subject', '⏰ Reminder: ' || r.title,
                   'html',    format(
                     '<h2>⏰ Coming up soon</h2>'
                     '<p style="font-size:18px"><b>%s</b></p>'
                     '<p>%s</p>'
                     '<p>Open <a href="https://thequestcraft.com">thequestcraft.com</a> to see your schedule.</p>'
                     '<p style="color:#888;font-size:12px">You can turn these emails off in QuestCraft → Settings.</p>',
                     safe, coalesce(r.when_label, ''))
                 )
    );
    update event_reminders set sent_at = now() where id = r.id;
    sent := sent + 1;
  end loop;
  return sent;
end $$;

revoke all on function public.send_due_reminders() from public, anon, authenticated;

-- (re)create the every-minute job
select cron.unschedule(jobid) from cron.job where jobname = 'qc-event-reminders';
select cron.schedule('qc-event-reminders', '* * * * *', 'select public.send_due_reminders()');
