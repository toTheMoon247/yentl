-- Fix: consumers couldn't see other users' live photos/prompts in discovery.
--
-- The "live content is readable" policies (added in 20260603171739) checked
-- liveness with a sub-query against public.profiles:
--     exists (select 1 from public.profiles p
--             where p.id = <owner> and p.review_state = 'live')
-- That sub-query runs under the CALLER's RLS, and public.profiles is readable
-- only by the row owner or staff (is_matchmaker_or_admin). So a normal consumer
-- could never satisfy it for anyone else — every other person's photo row read
-- and storage object read were denied, and discovery showed placeholders.
-- (Staff accounts worked, which is why it looked fine for an admin tester.)
--
-- Fix: check liveness through a SECURITY DEFINER function that bypasses
-- profiles RLS, and rewrite the three "live" policies to use it. It exposes
-- only a boolean ("is this profile live?"), never the hidden profile columns
-- (height/income), which stay owner/staff-only on the profiles table itself.

create or replace function public.is_profile_live(p_id text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
    select exists (
        select 1 from public.profiles p
        where p.id::text = p_id and p.review_state = 'live'
    );
$$;

revoke execute on function public.is_profile_live(text) from public, anon;
grant execute on function public.is_profile_live(text) to authenticated;

-- profile_photos: live owners' rows readable by any authenticated user.
drop policy if exists profile_photos_select_live on public.profile_photos;
create policy profile_photos_select_live on public.profile_photos
    for select to authenticated
    using (public.is_profile_live(user_id::text));

-- profile_prompts: same.
drop policy if exists profile_prompts_select_live on public.profile_prompts;
create policy profile_prompts_select_live on public.profile_prompts
    for select to authenticated
    using (public.is_profile_live(user_id::text));

-- storage.objects: signed-URL reads for live owners' photo files.
drop policy if exists "profile-photos read live" on storage.objects;
create policy "profile-photos read live"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'profile-photos'
        and public.is_profile_live((storage.foldername(name))[1])
    );
