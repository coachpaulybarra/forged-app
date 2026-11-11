-- =====================================================================
-- FORGED: phone alerts (web push)
-- Run once in Supabase > SQL Editor.
-- =====================================================================
create table if not exists public.push_subscriptions (
  id bigint generated always as identity primary key,
  member_id bigint not null references public.members(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text not null default '',
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
drop policy if exists "own push subs read" on public.push_subscriptions;
drop policy if exists "own push subs add" on public.push_subscriptions;
drop policy if exists "own push subs remove" on public.push_subscriptions;
create policy "own push subs read" on public.push_subscriptions for select using (member_id = public.my_member_id());
create policy "own push subs add" on public.push_subscriptions for insert with check (member_id = public.my_member_id() and public.is_approved());
create policy "own push subs remove" on public.push_subscriptions for delete using (member_id = public.my_member_id());

-- Server-only settings (the push signing keys live here). No policies = no app access.
create table if not exists public.push_config (
  id int primary key default 1 check (id = 1),
  vapid_public text not null,
  vapid_private text not null,
  created_at timestamptz not null default now()
);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;

-- The notification function (service role) needs full access to both.
grant all on public.push_subscriptions, public.push_config to service_role;
