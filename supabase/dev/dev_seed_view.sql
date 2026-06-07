-- Dev-only: a public view exposing seeded profiles, joined to auth.users by the
-- seed email pattern. PostgREST (which the upload script uses) can't reach the
-- `auth` schema, so this view lets the script find seeds by email regardless of
-- their display names. Run once in the Studio SQL editor. NOT a migration —
-- this never ships to prod.
--
-- The view runs as its owner (postgres), so it can read auth.users; only
-- service_role can select it (that's what the upload script uses).

create or replace view public.dev_seed_profiles as
select p.id, p.display_name, p.gender
from public.profiles p
join auth.users u on u.id = p.id
where u.email like 'seed-%@yentl.test';

grant select on public.dev_seed_profiles to service_role;
