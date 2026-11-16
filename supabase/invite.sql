-- =====================================================================
-- FORGED: invite link + QR code. Men who sign up through the link are approved automatically.
-- Run once in Supabase > SQL Editor.
-- =====================================================================
create table if not exists public.invite_config (
  id int primary key default 1 check (id = 1),
  code text not null,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.invite_config enable row level security;
revoke all on public.invite_config from anon, authenticated;
grant all on public.invite_config to service_role;
insert into public.invite_config (id, code)
values (1, substr(md5(random()::text || clock_timestamp()::text), 1, 10))
on conflict (id) do nothing;

-- Coach Paul reads and manages the link from the Members page.
create or replace function public.get_invite() returns table (code text, active boolean)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not allowed'; end if;
  return query select c.code, c.active from invite_config c where c.id = 1;
end $$;
create or replace function public.set_invite(p_active boolean, p_new_code boolean default false)
returns table (code text, active boolean)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not allowed'; end if;
  update invite_config c set active = p_active,
    code = case when p_new_code then substr(md5(random()::text || clock_timestamp()::text), 1, 10) else c.code end,
    updated_at = now()
  where c.id = 1;
  return query select c.code, c.active from invite_config c where c.id = 1;
end $$;
revoke all on function public.get_invite(), public.set_invite(boolean, boolean) from public, anon;
grant execute on function public.get_invite(), public.set_invite(boolean, boolean) to authenticated;

-- New sign-ups: a valid, active invite code means approved right away.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare invited boolean := exists (
  select 1 from invite_config c
   where c.active and c.code = nullif(btrim(coalesce(new.raw_user_meta_data->>'invite', '')), ''));
begin
  update members set user_id = new.id
   where lower(email) = lower(new.email) and user_id is null;
  if not found then
    insert into members (user_id, name, email, note, status)
    values (new.id,
            coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)),
            lower(new.email),
            left(btrim(coalesce(new.raw_user_meta_data->>'note', '') || case when invited then ' (joined through the invite link)' else '' end), 500),
            case when invited then 'approved' else 'pending' end);
  end if;
  return new;
end $$;

-- Tell Coach Paul when someone joins through the link.
create or replace function private.on_member_change() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'approved' and new.user_id is null and new.email is not null then
      perform private.notify('member_added', jsonb_build_object('member_id', new.id));
    elsif new.status = 'approved' and new.user_id is not null then
      perform private.notify('invite_joined', jsonb_build_object('member_id', new.id));
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
