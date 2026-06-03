-- Dev-only: create one profile_photos row per seeded profile and emit an upload
-- manifest. Pairs with supabase/dev/upload_seed_photos.sh (CLI upload — no key).
--
-- Run this in the Supabase Studio SQL editor against DEV. The displayed result
-- is the manifest: export it as CSV (Export -> CSV) and pass that file to the
-- upload script.
--
-- Path scheme is {user_id}/seed.jpg so the discovery RLS (which scopes reads by
-- the user-id folder) can serve the photo. Re-running is safe: the unique
-- storage_path + ON CONFLICT keeps it idempotent.

insert into public.profile_photos (id, user_id, storage_path, order_index)
select gen_random_uuid(), id, id || '/seed.jpg', 0
from public.profiles
where display_name like 'Test %'
on conflict (storage_path) do nothing;

-- Manifest — export THIS result as CSV (columns: gender, ord, path):
select
    p.gender,
    row_number() over (partition by p.gender order by p.display_name) as ord,
    ph.storage_path as path
from public.profiles p
join public.profile_photos ph on ph.user_id = p.id
where p.display_name like 'Test %'
  and ph.storage_path like '%/seed.jpg'
order by p.gender, ord;
