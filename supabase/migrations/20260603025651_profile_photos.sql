-- Phase 2 (Slice 2): profile photos — table + private storage bucket.
--
-- Photos live in Supabase Storage (the `profile-photos` bucket); this table
-- holds one row per photo with its storage path and display order. Files are
-- stored under a per-user folder: `{user_id}/{photo_id}.jpg`, so the storage
-- RLS can scope access by the first path segment.
--
-- Variant generation (thumb/medium/full) is deferred within Phase 2; for now
-- a single downscaled JPEG is uploaded per photo.

create table public.profile_photos (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references public.users(id) on delete cascade,
    storage_path text not null unique,
    order_index  int  not null default 0,
    created_at   timestamptz not null default now()
);

create index profile_photos_user_order_idx
    on public.profile_photos (user_id, order_index);

alter table public.profile_photos enable row level security;

-- Owner can read/write/delete their own photo rows.
create policy profile_photos_select_own
    on public.profile_photos for select to authenticated
    using (auth.uid() = user_id);

create policy profile_photos_insert_own
    on public.profile_photos for insert to authenticated
    with check (auth.uid() = user_id);

create policy profile_photos_update_own
    on public.profile_photos for update to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy profile_photos_delete_own
    on public.profile_photos for delete to authenticated
    using (auth.uid() = user_id);

-- Matchmakers and admins can read everyone's photo rows (later phases).
create policy profile_photos_select_all_for_staff
    on public.profile_photos for select to authenticated
    using (public.is_matchmaker_or_admin());

------------------------------------------------------------------------
-- Storage: private bucket + RLS on storage.objects
------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('profile-photos', 'profile-photos', false)
on conflict (id) do nothing;

-- Files are addressed by signed URLs; access is scoped to the user's own
-- `{user_id}/...` folder (first path segment must equal the caller's uid).
create policy "profile-photos read own"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'profile-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "profile-photos insert own"
    on storage.objects for insert to authenticated
    with check (
        bucket_id = 'profile-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "profile-photos update own"
    on storage.objects for update to authenticated
    using (
        bucket_id = 'profile-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
    )
    with check (
        bucket_id = 'profile-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "profile-photos delete own"
    on storage.objects for delete to authenticated
    using (
        bucket_id = 'profile-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "profile-photos staff read all"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'profile-photos'
        and public.is_matchmaker_or_admin()
    );
