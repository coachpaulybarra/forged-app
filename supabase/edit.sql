-- FORGED: edit your own posts and replies (Nov 25, 2026)
-- A man can fix the words of his own post, reply or comment. Nobody can edit
-- someone else's words, admins included (admins can still delete).
-- An edited post shows "(edited)". Editing doesn't re-send alerts.
-- Safe to run more than once.

alter table public.messages add column if not exists edited_at timestamptz;

create or replace function public.edit_message(p_id bigint, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare me bigint := my_member_id(); b text := btrim(coalesce(p_body, '')); img text;
begin
  if me is null or not is_approved() then raise exception 'Only approved members can edit posts.'; end if;
  select image_key into img from messages where id = p_id and member_id = me;
  if not found then raise exception 'You can only edit your own posts.'; end if;
  if b = '' and img is null then raise exception 'A post can''t be empty. Delete it instead.'; end if;
  if char_length(b) > 5000 then raise exception 'Keep it under 5,000 characters.'; end if;
  update messages set body = b, edited_at = now() where id = p_id and member_id = me and body is distinct from b;
end $$;
revoke all on function public.edit_message(bigint, text) from public, anon;
grant execute on function public.edit_message(bigint, text) to authenticated;

select 'editing ready' as status;
