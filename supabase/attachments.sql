-- =====================================================================
-- FORGED: attach a worksheet (PDF) to any teaching
-- Run once in Supabase > SQL Editor.
-- =====================================================================
alter table public.teachings add column if not exists attach_key text;
alter table public.teachings add column if not exists attach_name text;
