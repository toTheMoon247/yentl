-- Phase 4 (Slice 1): profile review state, swipes, and the discovery feed.
--
-- Review state is mocked for MVP — profiles go 'live' on completion (folded in
-- from the old Phase 3; the real approval pipeline is Phase 12). Discovery
-- shows only live profiles.
--
-- Hidden matchmaker fields (height/income) are protected from other consumers
-- here: the profiles table RLS still allows only owner + staff to read rows,
-- and the discovery_feed() RPC is a security-definer projection that returns
-- ONLY public columns. Photos and prompts of live profiles are made readable
-- so candidates can be displayed.

-- ---------------------------------------------------------------------------
-- Review state (mock)
-- ---------------------------------------------------------------------------
create type public.profile_review_state as enum
    ('draft', 'pending_ai', 'pending_review', 'live', 'rejected');

alter table public.profiles
    add column review_state public.profile_review_state not null default 'pending_review';

-- Backfill: existing completed profiles are live (MVP mock).
update public.profiles
set review_state = 'live'
where profile_completed_at is not null;

-- ---------------------------------------------------------------------------
-- Swipes
-- ---------------------------------------------------------------------------
create type public.swipe_action as enum ('like', 'pass');

create table public.swipes (
    id         uuid primary key default gen_random_uuid(),
    from_user  uuid not null references public.users(id) on delete cascade,
    to_user    uuid not null references public.users(id) on delete cascade,
    action     public.swipe_action not null,
    created_at timestamptz not null default now(),
    unique (from_user, to_user),
    check (from_user <> to_user)
);

create index swipes_from_user_idx on public.swipes (from_user);
create index swipes_to_user_action_idx on public.swipes (to_user, action);

alter table public.swipes enable row level security;

-- You can read and create your own swipes.
create policy swipes_select_own on public.swipes
    for select to authenticated using (auth.uid() = from_user);
create policy swipes_insert_own on public.swipes
    for insert to authenticated with check (auth.uid() = from_user);

-- Note: there is intentionally NO policy letting a user read the likes they
-- received. Yentl has no consumer-facing "likes you" feed — received-like data
-- is for the matchmaker's candidate ordering only (read via the staff policy).

-- Staff can read all swipes (later phases).
create policy swipes_select_all_for_staff on public.swipes
    for select to authenticated using (public.is_matchmaker_or_admin());

-- ---------------------------------------------------------------------------
-- Make live profiles' photos + prompts readable to other consumers
-- (these are public content; the hidden fields live on the profiles row,
-- which stays owner/staff-only).
-- ---------------------------------------------------------------------------
create policy profile_photos_select_live on public.profile_photos
    for select to authenticated
    using (exists (
        select 1 from public.profiles p
        where p.id = profile_photos.user_id and p.review_state = 'live'
    ));

create policy profile_prompts_select_live on public.profile_prompts
    for select to authenticated
    using (exists (
        select 1 from public.profiles p
        where p.id = profile_prompts.user_id and p.review_state = 'live'
    ));

create policy "profile-photos read live"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'profile-photos'
        and exists (
            select 1 from public.profiles p
            where p.id::text = (storage.foldername(name))[1]
              and p.review_state = 'live'
        )
    );

-- ---------------------------------------------------------------------------
-- Discovery feed — security-definer projection of PUBLIC columns only.
-- Candidates: live, completed, opposite gender (hetero MVP), not yet swiped
-- by the caller, excluding the caller. Most-recent first for now.
-- ---------------------------------------------------------------------------
create or replace function public.discovery_feed(limit_count int default 20)
returns table (
    id            uuid,
    display_name  text,
    date_of_birth date,
    gender        public.gender,
    location      text,
    bio           text,
    interests     text[]
)
language sql
security definer
set search_path = public
as $$
    select p.id, p.display_name, p.date_of_birth, p.gender, p.location, p.bio, p.interests
    from public.profiles p
    where p.review_state = 'live'
      and p.profile_completed_at is not null
      and p.id <> auth.uid()
      and p.gender <> (select gender from public.profiles where id = auth.uid())
      and not exists (
          select 1 from public.swipes s
          where s.from_user = auth.uid() and s.to_user = p.id
      )
    order by p.created_at desc
    limit limit_count
$$;

revoke execute on function public.discovery_feed(int) from public, anon;
grant execute on function public.discovery_feed(int) to authenticated;
