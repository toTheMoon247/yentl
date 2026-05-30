-- Phase 1: Users table with role column + RLS policies.
--
-- public.users extends auth.users (managed by Supabase Auth) with the
-- app-specific role field. A row is auto-created via trigger when a
-- new auth.users row appears.

-- Role enum
create type public.user_role as enum ('user', 'matchmaker', 'admin');

-- Users table — one row per auth.users row, same id
create table public.users (
    id         uuid primary key references auth.users(id) on delete cascade,
    role       public.user_role not null default 'user',
    created_at timestamptz      not null default now(),
    updated_at timestamptz      not null default now()
);

-- Auto-create public.users row when auth.users row is inserted
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.users (id) values (new.id);
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- Keep updated_at fresh on every update
create or replace function public.handle_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger users_updated_at
    before update on public.users
    for each row execute function public.handle_updated_at();

-- Security-definer helper used inside RLS policies to avoid recursive
-- RLS evaluation when checking the caller's role.
create or replace function public.is_matchmaker_or_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
    select role in ('matchmaker', 'admin')
    from public.users
    where id = auth.uid()
$$;

-- Enable RLS
alter table public.users enable row level security;

-- A user can read their own row.
create policy users_select_own
    on public.users
    for select
    to authenticated
    using (auth.uid() = id);

-- Matchmakers and admins can read all user rows (needed for the
-- matchmaking workflow in later phases).
create policy users_select_all_for_staff
    on public.users
    for select
    to authenticated
    using (public.is_matchmaker_or_admin());

-- No INSERT policy: rows are created via the on_auth_user_created trigger.
-- No UPDATE policy yet: role changes go through the service role (admin flow).
-- No DELETE policy: handled by cascade from auth.users.
