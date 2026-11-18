-- FORGED: the FORGED Code (Nov 18, 2026)
-- Each man agrees once. It's saved on his member card, so it never shows again
-- on any phone or computer. The member export shows who has agreed.
-- Safe to run more than once.

alter table public.members add column if not exists code_agreed_at timestamptz;

create or replace function public.agree_code() returns void
language sql security definer set search_path = public as $$
  update members set code_agreed_at = coalesce(code_agreed_at, now()) where user_id = auth.uid();
$$;
revoke all on function public.agree_code() from public, anon;
grant execute on function public.agree_code() to authenticated;

select count(*) as men, count(code_agreed_at) as agreed from public.members;
