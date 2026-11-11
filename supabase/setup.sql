-- =====================================================================
-- FORGED APP — DATABASE SETUP
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- Before you run it: change the email on the line marked  >>> EDIT <<<
-- Safe to run once on a brand-new Supabase project.
-- =====================================================================

-- ---------- TABLES ----------
create table public.members (
  id bigint generated always as identity primary key,
  user_id uuid unique references auth.users(id) on delete set null,
  name text not null,
  email text unique,
  role text not null default 'member' check (role in ('member','moderator','admin')),
  status text not null default 'pending' check (status in ('pending','approved','declined')),
  note text not null default '',
  digest_opt_out boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.teachings (
  id bigint generated always as identity primary key,
  title text not null,
  description text not null default '',
  kind text not null check (kind in ('video','audio','pdf')),
  source text not null check (source in ('youtube','drive','link','upload')),
  url text not null default '',
  file_name text not null default '',
  mime_type text not null default '',
  pinned boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.events (
  id bigint generated always as identity primary key,
  title text not null,
  description text not null default '',
  event_date date not null,
  start_time text not null default '',
  end_time text not null default '',
  timezone text not null default 'America/Denver',
  location text not null default '',
  zoom_url text not null default '',
  created_at timestamptz not null default now()
);

create table public.rsvps (
  id bigint generated always as identity primary key,
  event_id bigint not null references public.events(id) on delete cascade,
  member_id bigint not null references public.members(id) on delete cascade,
  member_name text not null default '',
  created_at timestamptz not null default now(),
  unique (event_id, member_id)
);

create table public.channels (
  id bigint generated always as identity primary key,
  name text not null,
  description text not null default '',
  sort_order int not null default 1,
  created_at timestamptz not null default now()
);

create table public.messages (
  id bigint generated always as identity primary key,
  member_id bigint not null references public.members(id) on delete cascade,
  member_name text not null default '',
  body text not null default '',
  image_key text,
  channel_id bigint references public.channels(id) on delete cascade,
  teaching_id bigint references public.teachings(id) on delete cascade,
  created_at timestamptz not null default now(),
  check ((channel_id is null) <> (teaching_id is null))
);
create index on public.messages (channel_id, created_at);
create index on public.messages (teaching_id, created_at);

create table public.reads (
  member_id bigint not null references public.members(id) on delete cascade,
  scope text not null,
  read_at timestamptz not null default now(),
  primary key (member_id, scope)
);

-- ---------- HELPERS ----------
create or replace function public.my_member_id() returns bigint
language sql stable security definer set search_path = public as $$
  select id from members where user_id = auth.uid() and status = 'approved'
$$;

create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where user_id = auth.uid() and status = 'approved')
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where user_id = auth.uid() and status = 'approved' and role = 'admin')
$$;

-- New sign-up: link to a member Coach Paul already added, or create a pending request
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update members set user_id = new.id
   where lower(email) = lower(new.email) and user_id is null;
  if not found then
    insert into members (user_id, name, email, note, status)
    values (new.id,
            coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)),
            lower(new.email),
            coalesce(new.raw_user_meta_data->>'note', ''),
            'pending');
  end if;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Stamp the poster's name on messages and RSVPs
create or replace function public.stamp_member_name() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select name into new.member_name from members where id = new.member_id;
  return new;
end $$;
create trigger messages_name before insert on public.messages for each row execute function public.stamp_member_name();
create trigger rsvps_name before insert on public.rsvps for each row execute function public.stamp_member_name();

-- Member list: admins see everything, members see approved names only
create or replace function public.list_members()
returns table (id bigint, name text, email text, role text, status text, note text, created_at timestamptz, has_account boolean)
language sql stable security definer set search_path = public as $$
  select m.id, m.name,
         case when public.is_admin() then coalesce(m.email,'') else '' end,
         m.role, m.status,
         case when public.is_admin() then m.note else '' end,
         m.created_at, m.user_id is not null
    from members m
   where public.is_admin() or (public.is_approved() and m.status = 'approved')
$$;

create or replace function public.set_digest(wants boolean) returns void
language sql security definer set search_path = public as $$
  update members set digest_opt_out = not wants where user_id = auth.uid()
$$;

-- Unread badges for the Community and Teachings tabs
create or replace function public.unread_counts() returns json
language sql stable security definer set search_path = public as $$
  with me as (select id, created_at from members where user_id = auth.uid() and status = 'approved'),
  m as (
    select msg.channel_id, msg.teaching_id, msg.created_at,
           coalesce((select r.read_at from reads r, me
                      where r.member_id = me.id
                        and r.scope = case when msg.channel_id is not null
                                           then 'channel:' || msg.channel_id
                                           else 'teaching:' || msg.teaching_id end),
                    (select created_at from me)) as seen
      from messages msg, me
     where msg.member_id <> me.id
  )
  select json_build_object(
    'channels',  coalesce((select json_object_agg(channel_id, c) from (select channel_id, count(*) c from m where channel_id is not null and created_at > seen group by channel_id) x), '{}'::json),
    'teachings', coalesce((select json_object_agg(teaching_id, c) from (select teaching_id, count(*) c from m where teaching_id is not null and created_at > seen group by teaching_id) y), '{}'::json))
$$;

-- ---------- SECURITY (row level) ----------
alter table public.members   enable row level security;
alter table public.teachings enable row level security;
alter table public.events    enable row level security;
alter table public.rsvps     enable row level security;
alter table public.channels  enable row level security;
alter table public.messages  enable row level security;
alter table public.reads     enable row level security;

create policy "own row or admin" on public.members for select using (user_id = auth.uid() or public.is_admin());
create policy "admin adds"    on public.members for insert with check (public.is_admin());
create policy "admin edits"   on public.members for update using (public.is_admin());
create policy "admin removes" on public.members for delete using (public.is_admin());

create policy "members read" on public.teachings for select using (public.is_approved());
create policy "admin writes" on public.teachings for all using (public.is_admin()) with check (public.is_admin());

create policy "members read" on public.events for select using (public.is_approved());
create policy "admin writes" on public.events for all using (public.is_admin()) with check (public.is_admin());

create policy "members read" on public.rsvps for select using (public.is_approved());
create policy "rsvp self"    on public.rsvps for insert with check (member_id = public.my_member_id());
create policy "un-rsvp self" on public.rsvps for delete using (member_id = public.my_member_id() or public.is_admin());

create policy "members read" on public.channels for select using (public.is_approved());
create policy "admin writes" on public.channels for all using (public.is_admin()) with check (public.is_admin());

create policy "members read" on public.messages for select using (public.is_approved());
create policy "post as self" on public.messages for insert with check (member_id = public.my_member_id());
create policy "delete own or admin" on public.messages for delete using (member_id = public.my_member_id() or public.is_admin());

create policy "own reads" on public.reads for all using (member_id = public.my_member_id()) with check (member_id = public.my_member_id());

-- ---------- FILE STORAGE ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('teachings', 'teachings', false, 52428800),
       ('images',    'images',    false, 10485760);

create policy "members view teaching files" on storage.objects for select using (bucket_id = 'teachings' and public.is_approved());
create policy "admin uploads teaching files" on storage.objects for insert with check (bucket_id = 'teachings' and public.is_admin());
create policy "admin deletes teaching files" on storage.objects for delete using (bucket_id = 'teachings' and public.is_admin());

create policy "members view chat photos" on storage.objects for select using (bucket_id = 'images' and public.is_approved());
create policy "members upload own photos" on storage.objects for insert with check (bucket_id = 'images' and public.is_approved() and (storage.foldername(name))[1] = public.my_member_id()::text);
create policy "delete own photos or admin" on storage.objects for delete using (bucket_id = 'images' and ((storage.foldername(name))[1] = public.my_member_id()::text or public.is_admin()));

-- ---------- STARTING CONTENT ----------
-- >>> EDIT <<<  Put the email YOU will sign in with between the quotes:
insert into public.members (name, email, role, status)
values ('Coach Paul Ybarra', lower('YOUR-EMAIL@EXAMPLE.COM'), 'admin', 'approved');

insert into public.channels (name, description, sort_order) values
  ('Brotherhood', 'Your verse, your win, your fight. Say it here. Iron sharpens iron.', 1),
  ('Prayer', 'Prayer requests and praise reports. Nobody stands alone.', 2);
