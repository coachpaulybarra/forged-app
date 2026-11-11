-- =====================================================================
-- FORGED: @mentions (tag a brother; he gets an email)
-- Run once in Supabase > SQL Editor.
-- =====================================================================
alter table public.messages add column if not exists mentions bigint[] not null default '{}';

create or replace function private.on_message_insert() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.parent_id is null and new.channel_id is not null
     and exists (select 1 from channels where id = new.channel_id and instant) then
    perform private.notify('prayer', jsonb_build_object('message_id', new.id));
  end if;
  if coalesce(array_length(new.mentions, 1), 0) > 0 then
    perform private.notify('mention', jsonb_build_object('message_id', new.id));
  end if;
  return new;
end $$;
