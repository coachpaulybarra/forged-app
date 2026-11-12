-- =====================================================================
-- FORGED: Brotherhood alerts
--   * a member's new post in Brotherhood (any non-prayer chat) -> phone alert to Coach Paul
--   * a reply to a post -> phone alert to the man who wrote that post
-- Run once in Supabase > SQL Editor.
-- =====================================================================
create or replace function private.on_message_insert() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare inst boolean := false;
begin
  if not new.released then return new; end if;
  if new.channel_id is not null then select instant into inst from channels where id = new.channel_id; end if;
  if new.parent_id is null and new.channel_id is not null and coalesce(inst, false) then
    perform private.notify('prayer', jsonb_build_object('message_id', new.id));
  end if;
  if new.parent_id is null and new.channel_id is not null and not coalesce(inst, false) then
    perform private.notify('post', jsonb_build_object('message_id', new.id));
  end if;
  if new.parent_id is not null then
    perform private.notify('reply', jsonb_build_object('message_id', new.id));
  end if;
  if coalesce(array_length(new.mentions, 1), 0) > 0 then
    perform private.notify('mention', jsonb_build_object('message_id', new.id));
  end if;
  return new;
end $$;
