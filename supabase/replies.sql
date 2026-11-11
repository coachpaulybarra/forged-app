-- =====================================================================
-- FORGED: posts with replies (Brotherhood + Prayer become post cards)
-- Run once in Supabase > SQL Editor.
-- =====================================================================
alter table public.messages add column if not exists parent_id bigint references public.messages(id) on delete cascade;
create index if not exists messages_parent_idx on public.messages (parent_id);

-- A reply always lives in the same place as its post, and replies stay one level deep.
create or replace function public.fix_reply() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if new.parent_id is not null then
    select id, parent_id, channel_id, teaching_id into p from messages where id = new.parent_id;
    if not found then raise exception 'That post no longer exists.'; end if;
    if p.parent_id is not null then new.parent_id := p.parent_id; end if;  -- reply to a reply -> attach to the post
    new.channel_id := p.channel_id;
    new.teaching_id := p.teaching_id;
  end if;
  return new;
end $$;
drop trigger if exists messages_fix_reply on public.messages;
create trigger messages_fix_reply before insert on public.messages
  for each row execute function public.fix_reply();

-- Prayer alerts go out for new prayer requests only, not for every reply.
create or replace function private.on_message_insert() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.parent_id is null and new.channel_id is not null
     and exists (select 1 from channels where id = new.channel_id and instant) then
    perform private.notify('prayer', jsonb_build_object('message_id', new.id));
  end if;
  return new;
end $$;
