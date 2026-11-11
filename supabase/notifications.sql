-- =====================================================================
-- FORGED NOTIFICATIONS: wiring between the database and the forged-notify function
-- Run once in Supabase > SQL Editor, AFTER the forged-notify function is deployed.
-- =====================================================================
create extension if not exists pg_net;
create extension if not exists pg_cron;

-- Prayer is the "right away" chat
alter table public.channels add column if not exists instant boolean not null default false;
update public.channels set instant = true where lower(name) = 'prayer';

-- Remembers when the last digest went out (only the function touches this)
create table if not exists public.notify_state (
  id int primary key default 1,
  last_digest_at timestamptz,
  last_digest_day text
);
alter table public.notify_state enable row level security;  -- no policies: invisible to the app

-- Private settings: the function address and a shared secret
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.settings (key text primary key, value text not null);
insert into private.settings (key, value) values
  ('notify_url', 'https://qsdssjbpewgmvlrvjpzv.supabase.co/functions/v1/forged-notify'),
  ('notify_secret', '__NOTIFY_SECRET__')
on conflict (key) do update set value = excluded.value;

create or replace function private.notify(kind text, payload jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public, private as $$
declare u text; s text;
begin
  select value into u from private.settings where key = 'notify_url';
  select value into s from private.settings where key = 'notify_secret';
  perform net.http_post(
    url := u,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-forged-secret', s),
    body := payload || jsonb_build_object('type', kind),
    timeout_milliseconds := 20000
  );
end $$;

-- New post in an "instant" chat (Prayer) -> email the brothers right away
create or replace function private.on_message_insert() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.channel_id is not null and exists (select 1 from channels where id = new.channel_id and instant) then
    perform private.notify('prayer', jsonb_build_object('message_id', new.id));
  end if;
  return new;
end $$;
drop trigger if exists notify_message on public.messages;
create trigger notify_message after insert on public.messages
  for each row execute function private.on_message_insert();

-- Member events: Coach Paul adds a man, a man requests access, a request is approved
create or replace function private.on_member_change() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'approved' and new.user_id is null and new.email is not null then
      perform private.notify('member_added', jsonb_build_object('member_id', new.id));
    elsif new.status = 'pending' then
      perform private.notify('new_request', jsonb_build_object('member_id', new.id));
    end if;
  elsif tg_op = 'UPDATE' then
    if old.status <> 'approved' and new.status = 'approved' and new.user_id is not null then
      perform private.notify('approved', jsonb_build_object('member_id', new.id));
    end if;
  end if;
  return new;
end $$;
drop trigger if exists notify_member on public.members;
create trigger notify_member after insert or update of status on public.members
  for each row execute function private.on_member_change();

-- Hourly tick; the function only sends at 6 PM Mountain (handles daylight saving)
select cron.unschedule('forged-digest-tick') where exists (select 1 from cron.job where jobname = 'forged-digest-tick');
select cron.schedule('forged-digest-tick', '0 * * * *', $$ select private.notify('digest_tick') $$);
