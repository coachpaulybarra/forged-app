-- FORGED: direct messages (Nov 18, 2026)
-- One-on-one messages between approved men.
--   * Only the two men can read a conversation. There is no admin view.
--   * Block: a man can stop another man from messaging him.
--   * Report: copies the last 50 messages of that conversation to the admins
--     so Coach Paul can step in. That copy is the only thing an admin ever sees.
--   * A new message buzzes the other man's phone ("Tap to read it", no preview).
-- Everything goes through the functions below; the tables have no direct access.
-- Safe to run more than once.

create table if not exists public.direct_messages (
  id bigint generated always as identity primary key,
  sender_id bigint not null references public.members(id) on delete cascade,
  recipient_id bigint not null references public.members(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  check (sender_id <> recipient_id)
);
create index if not exists dm_pair_idx on public.direct_messages (least(sender_id, recipient_id), greatest(sender_id, recipient_id), created_at desc);
create index if not exists dm_unread_idx on public.direct_messages (recipient_id) where read_at is null;
alter table public.direct_messages enable row level security;

create table if not exists public.dm_blocks (
  blocker_id bigint not null references public.members(id) on delete cascade,
  blocked_id bigint not null references public.members(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);
alter table public.dm_blocks enable row level security;

create table if not exists public.dm_reports (
  id bigint generated always as identity primary key,
  reporter_id bigint references public.members(id) on delete set null,
  other_id bigint references public.members(id) on delete set null,
  reporter_name text not null default '',
  other_name text not null default '',
  reason text not null default '',
  snapshot jsonb not null default '[]',
  created_at timestamptz not null default now(),
  handled_at timestamptz
);
alter table public.dm_reports enable row level security;

-- Send a message.
create or replace function public.dm_send(p_to bigint, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare me bigint := my_member_id(); b text := btrim(coalesce(p_body, '')); nid bigint;
begin
  if me is null or not is_approved() then raise exception 'Only approved members can send messages.'; end if;
  if p_to = me then raise exception 'You can''t message yourself.'; end if;
  if not exists (select 1 from members where id = p_to and status = 'approved') then raise exception 'That brother isn''t in FORGED right now.'; end if;
  if b = '' then raise exception 'Write a message first.'; end if;
  if char_length(b) > 2000 then raise exception 'Keep it under 2,000 characters.'; end if;
  if exists (select 1 from dm_blocks where blocker_id = me and blocked_id = p_to) then raise exception 'You blocked him. Unblock him to send a message.'; end if;
  if exists (select 1 from dm_blocks where blocker_id = p_to and blocked_id = me) then raise exception 'You can''t message this brother right now.'; end if;
  insert into direct_messages (sender_id, recipient_id, body) values (me, p_to, b) returning id into nid;
  return nid;
end $$;

-- My conversation list.
create or replace function public.dm_conversations() returns json
language sql security definer stable set search_path = public as $$
  with me as (select my_member_id() as id),
  t as (
    select case when d.sender_id = me.id then d.recipient_id else d.sender_id end as other, d.*
      from direct_messages d, me
     where me.id is not null and (d.sender_id = me.id or d.recipient_id = me.id)
  ),
  last as (select distinct on (other) other, body, created_at, sender_id from t order by other, created_at desc),
  unread as (select other, count(*) n from t, me where t.recipient_id = me.id and t.read_at is null group by other)
  select coalesce(json_agg(json_build_object(
      'id', m.id, 'name', m.name, 'avatar_key', m.avatar_key,
      'last', l.body, 'at', l.created_at, 'mine', l.sender_id = (select id from me),
      'unread', coalesce(u.n, 0),
      'blocked', exists (select 1 from dm_blocks where blocker_id = (select id from me) and blocked_id = m.id)
    ) order by l.created_at desc), '[]'::json)
  from last l join members m on m.id = l.other left join unread u on u.other = l.other;
$$;

-- One conversation (newest 200). Marks his messages to me as read.
create or replace function public.dm_thread(p_other bigint) returns json
language plpgsql security definer set search_path = public as $$
declare me bigint := my_member_id(); r json;
begin
  if me is null or not is_approved() then raise exception 'Only approved members can read messages.'; end if;
  update direct_messages set read_at = now() where recipient_id = me and sender_id = p_other and read_at is null;
  select json_build_object(
    'other', (select json_build_object('id', id, 'name', name, 'avatar_key', avatar_key, 'status', status, 'has_login', user_id is not null) from members where id = p_other),
    'blocked', exists (select 1 from dm_blocks where blocker_id = me and blocked_id = p_other),
    'messages', coalesce((select json_agg(x order by x.created_at) from (
        select id, sender_id = me as mine, body, created_at, read_at is not null as seen
          from direct_messages
         where (sender_id = me and recipient_id = p_other) or (sender_id = p_other and recipient_id = me)
         order by created_at desc limit 200) x), '[]'::json)
  ) into r;
  return r;
end $$;

create or replace function public.dm_unread() returns int
language sql security definer stable set search_path = public as $$
  select count(*)::int from direct_messages where recipient_id = my_member_id() and read_at is null;
$$;

create or replace function public.dm_block(p_other bigint, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me bigint := my_member_id();
begin
  if me is null or not is_approved() then raise exception 'Only approved members can do that.'; end if;
  if p_on then
    insert into dm_blocks (blocker_id, blocked_id) values (me, p_other) on conflict do nothing;
  else
    delete from dm_blocks where blocker_id = me and blocked_id = p_other;
  end if;
end $$;

-- Report a conversation to the admins (copies the last 50 messages).
create or replace function public.dm_report(p_other bigint, p_reason text) returns void
language plpgsql security definer set search_path = public, private as $$
declare me bigint := my_member_id(); rid bigint;
begin
  if me is null or not is_approved() then raise exception 'Only approved members can do that.'; end if;
  insert into dm_reports (reporter_id, other_id, reporter_name, other_name, reason, snapshot)
  select me, p_other,
         (select name from members where id = me), coalesce((select name from members where id = p_other), ''),
         left(btrim(coalesce(p_reason, '')), 1000),
         coalesce((select json_agg(x order by x.created_at) from (
             select d.created_at, s.name as from_name, d.body
               from direct_messages d join members s on s.id = d.sender_id
              where (d.sender_id = me and d.recipient_id = p_other) or (d.sender_id = p_other and d.recipient_id = me)
              order by d.created_at desc limit 50) x), '[]'::json)::jsonb
  returning id into rid;
  perform private.notify('dm_report', jsonb_build_object('report_id', rid));
end $$;

-- Admins: open reports, and mark one handled.
create or replace function public.dm_reports_open() returns json
language plpgsql security definer stable set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only.'; end if;
  return coalesce((select json_agg(json_build_object('id', id, 'reporter', reporter_name, 'other', other_name,
      'reason', reason, 'snapshot', snapshot, 'at', created_at) order by created_at desc)
    from dm_reports where handled_at is null), '[]'::json);
end $$;

create or replace function public.dm_report_handled(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only.'; end if;
  update dm_reports set handled_at = now() where id = p_id;
end $$;

do $$ declare f text; begin
  foreach f in array array['dm_send(bigint,text)','dm_conversations()','dm_thread(bigint)','dm_unread()',
                           'dm_block(bigint,boolean)','dm_report(bigint,text)','dm_reports_open()','dm_report_handled(bigint)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- Phone alert for a new message.
create or replace function private.on_dm_insert() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.notify('dm', jsonb_build_object('message_id', new.id));
  return new;
end $$;
drop trigger if exists dm_notify on public.direct_messages;
create trigger dm_notify after insert on public.direct_messages
  for each row execute function private.on_dm_insert();

select 'direct messages ready' as status;
