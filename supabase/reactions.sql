-- =====================================================================
-- FORGED: reactions on posts and replies (🙏 🔥 💪 ❤️)
-- Run once in Supabase > SQL Editor.
-- =====================================================================
create table if not exists public.reactions (
  message_id bigint not null references public.messages(id) on delete cascade,
  member_id bigint not null references public.members(id) on delete cascade,
  emoji text not null check (emoji in ('pray','fire','strong','love')),
  created_at timestamptz not null default now(),
  primary key (message_id, member_id, emoji)
);
create index if not exists reactions_message_idx on public.reactions(message_id);
alter table public.reactions enable row level security;
drop policy if exists "members see reactions" on public.reactions;
drop policy if exists "members add own reaction" on public.reactions;
drop policy if exists "members remove own reaction" on public.reactions;
create policy "members see reactions" on public.reactions for select using (public.is_approved());
create policy "members add own reaction" on public.reactions for insert
  with check (member_id = public.my_member_id() and public.is_approved());
create policy "members remove own reaction" on public.reactions for delete using (member_id = public.my_member_id());
grant select, insert, delete on public.reactions to authenticated;
grant all on public.reactions to service_role;
