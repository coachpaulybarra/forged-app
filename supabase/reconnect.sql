-- FORGED: auto-reconnect logins (Nov 16, 2026)
-- 1. When Coach Paul adds (or re-adds) a man whose login already exists,
--    the card connects to that login on the spot and his email counts as confirmed.
-- 2. When a man signs in and has no card at all, a pending card is created
--    (or his old card is reconnected) so he shows up for approval instead of looping.
-- Safe to run more than once.

create or replace function private.link_existing_login() returns trigger
language plpgsql security definer set search_path = public, auth, private as $$
declare uid uuid;
begin
  if new.user_id is null and new.email is not null then
    select u.id into uid from auth.users u
     where lower(u.email) = lower(new.email)
       and not exists (select 1 from public.members m where m.user_id = u.id and m.id is distinct from new.id)
     limit 1;
    if uid is not null then
      new.user_id := uid;
      update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now()) where id = uid;
      perform set_config('forged.relinked', '1', true);
    end if;
  end if;
  return new;
end $$;

drop trigger if exists members_link_login on public.members;
create trigger members_link_login before insert or update of email on public.members
  for each row execute function private.link_existing_login();

-- Alerts: a re-added man is "added by Coach Paul", not "joined through the invite link".
create or replace function private.on_member_change() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare relinked boolean := coalesce(current_setting('forged.relinked', true), '') = '1';
begin
  if tg_op = 'INSERT' then
    if new.status = 'approved' and (new.user_id is null or relinked) and new.email is not null then
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
  perform set_config('forged.relinked', '', true);
  return new;
end $$;

-- Called by the app when a signed-in man has no card.
create or replace function public.ensure_my_card() returns void
language plpgsql security definer set search_path = public, auth as $$
declare uid uuid := auth.uid(); em text; nm text;
begin
  if uid is null then return; end if;
  if exists (select 1 from members where user_id = uid) then return; end if;
  select lower(email), coalesce(nullif(trim(raw_user_meta_data->>'name'), ''), split_part(email, '@', 1))
    into em, nm from auth.users where id = uid;
  if em is null then return; end if;
  update members set user_id = uid where lower(email) = em and user_id is null;
  if not found then
    insert into members (user_id, name, email, note, status)
    values (uid, nm, em, 'Signed in again after his card was removed', 'pending');
  end if;
end $$;
revoke all on function public.ensure_my_card() from public, anon;
grant execute on function public.ensure_my_card() to authenticated;

-- One-time sweep: reconnect any card that is sitting unconnected today.
update auth.users u set email_confirmed_at = coalesce(u.email_confirmed_at, now())
  from public.members m
 where m.user_id is null and lower(m.email) = lower(u.email)
   and not exists (select 1 from public.members x where x.user_id = u.id);
update public.members m set user_id = u.id
  from auth.users u
 where m.user_id is null and lower(m.email) = lower(u.email)
   and not exists (select 1 from public.members x where x.user_id = u.id);

select count(*) filter (where user_id is null) as cards_without_login,
       count(*) as total_cards
  from public.members;
