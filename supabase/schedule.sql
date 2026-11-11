-- =====================================================================
-- FORGED: scheduled posts (admin only)
-- Run once in Supabase > SQL Editor.
-- =====================================================================
alter table public.messages add column if not exists released boolean not null default true;

-- Only an admin can set a future time, and only on a top-level post. Everyone else posts "now".
create or replace function public.guard_message_time() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() and new.parent_id is null and new.created_at > now() + interval '1 minute' then
    new.released := false;
  else
    new.created_at := now();
    new.released := true;
  end if;
  return new;
end $$;
drop trigger if exists messages_guard_time on public.messages;
create trigger messages_guard_time before insert on public.messages
  for each row execute function public.guard_message_time();

-- Emails fire when a post goes live, not when it is scheduled.
create or replace function private.on_message_insert() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if not new.released then return new; end if;
  if new.parent_id is null and new.channel_id is not null
     and exists (select 1 from channels where id = new.channel_id and instant) then
    perform private.notify('prayer', jsonb_build_object('message_id', new.id));
  end if;
  if coalesce(array_length(new.mentions, 1), 0) > 0 then
    perform private.notify('mention', jsonb_build_object('message_id', new.id));
  end if;
  return new;
end $$;

-- Every minute: publish anything whose time has come, then send its emails.
create or replace function private.release_scheduled() returns void
language plpgsql security definer set search_path = public, private as $$
declare r record;
begin
  for r in select * from messages where not released and created_at <= now() for update skip locked loop
    update messages set released = true where id = r.id;
    if r.parent_id is null and r.channel_id is not null
       and exists (select 1 from channels where id = r.channel_id and instant) then
      perform private.notify('prayer', jsonb_build_object('message_id', r.id));
    end if;
    if coalesce(array_length(r.mentions, 1), 0) > 0 then
      perform private.notify('mention', jsonb_build_object('message_id', r.id));
    end if;
  end loop;
end $$;
select cron.unschedule('forged-release-scheduled') where exists (select 1 from cron.job where jobname = 'forged-release-scheduled');
select cron.schedule('forged-release-scheduled', '* * * * *', $$ select private.release_scheduled() $$);

-- Members never see a scheduled post early. Admins see it, marked as scheduled.
drop policy if exists "members read" on public.messages;
create policy "members read" on public.messages for select
  using (public.is_approved() and (released or public.is_admin()));

-- Unread badges ignore posts that are not live yet.
create or replace function public.unread_counts() returns json
language sql stable security definer set search_path = public as $$
  with me as (select id, created_at from members where user_id = auth.uid() and status = 'approved'),
  m as (
    select msg.channel_id, msg.teaching_id, msg.created_at,
           coalesce((select r.read_at from reads r, me
                      where r.member_id = me.id
                        and r.scope = case when msg.channel_id is not null
                                           then 'channel:' || msg.channel_id
                                           else 'teaching:' || msg.teaching_id end),
                    (select created_at from me)) as seen
      from messages msg, me
     where msg.member_id <> me.id and msg.released
  )
  select json_build_object(
    'channels',  coalesce((select json_object_agg(channel_id, c) from (select channel_id, count(*) c from m where channel_id is not null and created_at > seen group by channel_id) x), '{}'::json),
    'teachings', coalesce((select json_object_agg(teaching_id, c) from (select teaching_id, count(*) c from m where teaching_id is not null and created_at > seen group by teaching_id) y), '{}'::json))
$$;
