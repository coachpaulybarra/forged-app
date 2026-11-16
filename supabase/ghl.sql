-- =====================================================================
-- FORGED: send new members to GoHighLevel (growth hub) through an inbound webhook.
-- Run once in Supabase > SQL Editor.
-- =====================================================================
create table if not exists public.integration_config (
  id int primary key default 1 check (id = 1),
  ghl_webhook text,
  updated_at timestamptz not null default now()
);
alter table public.integration_config enable row level security;
revoke all on public.integration_config from anon, authenticated;
grant all on public.integration_config to service_role;
insert into public.integration_config (id) values (1) on conflict (id) do nothing;

-- Coach Paul saves the link; the app only ever sees whether it's set (plus its last few characters).
create or replace function public.get_ghl() returns table (connected boolean, hint text)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not allowed'; end if;
  return query select c.ghl_webhook is not null, right(coalesce(c.ghl_webhook, ''), 6) from integration_config c where c.id = 1;
end $$;
create or replace function public.set_ghl(p_url text) returns table (connected boolean, hint text)
language plpgsql security definer set search_path = public as $$
declare u text := nullif(btrim(coalesce(p_url, '')), '');
begin
  if not public.is_admin() then raise exception 'Not allowed'; end if;
  if u is not null and u !~ '^https://[A-Za-z0-9.-]+/' then raise exception 'That doesn''t look like a webhook link. It should start with https://'; end if;
  update integration_config set ghl_webhook = u, updated_at = now() where id = 1;
  return query select c.ghl_webhook is not null, right(coalesce(c.ghl_webhook, ''), 6) from integration_config c where c.id = 1;
end $$;
revoke all on function public.get_ghl(), public.set_ghl(text) from public, anon;
grant execute on function public.get_ghl(), public.set_ghl(text) to authenticated;
