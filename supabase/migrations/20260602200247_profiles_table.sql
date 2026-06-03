-- Phase 2 (Slice 1): profiles table — the user's dating profile.
--
-- One row per user, sharing the auth user's id. This slice covers the
-- "basics" only (name, DOB, gender, location); later slices add bio,
-- prompts, interests, photos, and the hidden matchmaker fields
-- (height, income) via follow-up migrations.
--
-- MVP is heterosexual matching only, so gender is male/female and the
-- "interested in" side is implied (opposite gender) — no column needed yet.
--
-- profile_completed_at is null until the creation wizard is finished; the
-- consumer app uses it to route a new user into the wizard vs. the home
-- screen. (The Phase 3 mock will let completed profiles go live immediately;
-- the review-state enum is added in that phase.)

create type public.gender as enum ('male', 'female');

create table public.profiles (
    id                   uuid primary key references public.users(id) on delete cascade,
    display_name         text not null,
    date_of_birth        date not null,
    gender               public.gender not null,
    location             text not null,
    profile_completed_at timestamptz,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now()
);

-- Keep updated_at fresh (reuses the helper from the users migration).
create trigger profiles_updated_at
    before update on public.profiles
    for each row execute function public.handle_updated_at();

alter table public.profiles enable row level security;

-- A user owns their profile: read and write only their own row.
create policy profiles_select_own
    on public.profiles
    for select
    to authenticated
    using (auth.uid() = id);

create policy profiles_insert_own
    on public.profiles
    for insert
    to authenticated
    with check (auth.uid() = id);

create policy profiles_update_own
    on public.profiles
    for update
    to authenticated
    using (auth.uid() = id)
    with check (auth.uid() = id);

-- Matchmakers and admins can read every profile (Decision Panel, later phases).
create policy profiles_select_all_for_staff
    on public.profiles
    for select
    to authenticated
    using (public.is_matchmaker_or_admin());

-- No DELETE policy: profile rows cascade away with the user.
-- Note: preventing *other consumers* from reading hidden fields is handled by
-- the public-profile projection in Phase 4 (discovery), not here.
