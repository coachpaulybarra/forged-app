-- =====================================================================
-- FORGED: member profiles (photo, about, life verse, what God is doing)
-- Run once in Supabase > SQL Editor.
-- =====================================================================
alter table public.members add column if not exists avatar_key text;
alter table public.members add column if not exists about text not null default '';
alter table public.members add column if not exists life_verse text not null default '';
alter table public.members add column if not exists working_on text not null default '';

-- Member list now carries profile fields (emails and notes stay admin-only).
drop function if exists public.list_members();
create function public.list_members()
returns table (id bigint, name text, email text, role text, status text, note text, created_at timestamptz, has_account boolean,
               avatar_key text, about text, life_verse text, working_on text)
language sql stable security definer set search_path = public as $$
  select m.id, m.name,
         case when public.is_admin() then coalesce(m.email,'') else '' end,
         m.role, m.status,
         case when public.is_admin() then m.note else '' end,
         m.created_at, m.user_id is not null,
         m.avatar_key, m.about, m.life_verse, m.working_on
    from members m
   where public.is_admin() or (public.is_approved() and m.status = 'approved')
$$;
grant execute on function public.list_members() to authenticated;

-- A man edits only his own profile.
create or replace function public.update_my_profile(p_name text, p_about text, p_life_verse text, p_working_on text)
returns void language plpgsql security definer set search_path = public as $$
declare mid bigint := public.my_member_id(); nm text := btrim(coalesce(p_name, ''));
begin
  if mid is null or not public.is_approved() then raise exception 'Not allowed'; end if;
  if nm = '' then raise exception 'Your name can''t be blank.'; end if;
  update members set
    name = left(nm, 80),
    about = left(btrim(coalesce(p_about, '')), 300),
    life_verse = left(btrim(coalesce(p_life_verse, '')), 200),
    working_on = left(btrim(coalesce(p_working_on, '')), 300)
  where id = mid;
  update messages set member_name = left(nm, 80) where member_id = mid and member_name is distinct from left(nm, 80);
  update rsvps set member_name = left(nm, 80) where member_id = mid and member_name is distinct from left(nm, 80);
end $$;

create or replace function public.set_my_avatar(p_key text)
returns text language plpgsql security definer set search_path = public as $$
declare mid bigint := public.my_member_id(); old text;
begin
  if mid is null or not public.is_approved() then raise exception 'Not allowed'; end if;
  if p_key is not null and p_key not like mid::text || '/%' then raise exception 'Not allowed'; end if;
  select avatar_key into old from members where id = mid;
  update members set avatar_key = p_key where id = mid;
  return old;
end $$;
revoke all on function public.update_my_profile(text, text, text, text), public.set_my_avatar(text) from public, anon;
grant execute on function public.update_my_profile(text, text, text, text), public.set_my_avatar(text) to authenticated;
