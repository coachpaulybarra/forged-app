-- =====================================================================
-- FORGED: pin a post to the top of a chat (admin only)
-- Run once in Supabase > SQL Editor.
-- =====================================================================
alter table public.messages add column if not exists pinned_at timestamptz;

create or replace function public.set_pin(mid bigint, turn_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only an admin can pin posts.'; end if;
  update messages set pinned_at = case when turn_on then now() else null end
   where id = mid and parent_id is null and channel_id is not null;
end $$;
revoke all on function public.set_pin(bigint, boolean) from public, anon;
grant execute on function public.set_pin(bigint, boolean) to authenticated;

-- New posts never arrive pinned; only set_pin() can pin.
create or replace function public.guard_message_pin() returns trigger
language plpgsql as $$ begin new.pinned_at := null; return new; end $$;
drop trigger if exists messages_guard_pin on public.messages;
create trigger messages_guard_pin before insert on public.messages
  for each row execute function public.guard_message_pin();
