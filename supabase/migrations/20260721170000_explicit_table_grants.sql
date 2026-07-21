-- Make table privileges explicit so the migrations can rebuild a working
-- database on their own.
--
-- Background: no migration ever granted table privileges. The live project
-- works only because Supabase's hosted platform sets ALTER DEFAULT PRIVILEGES
-- on schema public, so every table created there was granted to anon /
-- authenticated / service_role automatically. Those grants exist in the live
-- database but nowhere in this repo.
--
-- Two consequences, both real:
--   1. Running these migrations against a fresh Supabase project produces a
--      database where every app query fails with "permission denied".
--   2. The local CLI stack stopped reproducing that default (a Supabase CLI
--      change between 2026-06-11 and 2026-06-18), which turned CI red on a
--      docs-only commit and kept the pgTAP suite red for five weeks.
--
-- This migration mirrors the live grants exactly, as verified against the live
-- project on 2026-07-21: SELECT, INSERT, UPDATE, DELETE for anon,
-- authenticated and service_role on all seven public tables.
--
-- On `anon`: these grants look broad, but they are inert. RLS is the actual
-- gate and no policy in this schema names `anon` or `public` (verified). The
-- grants are mirrored rather than trimmed so that local, CI and production
-- behave identically — a policy that accidentally exposed data to anon should
-- fail in CI, not only in production.
--
-- Applying this to the live project is a no-op: it already has every grant
-- below.

grant select, insert, update, delete on table
    public.users,
    public.profiles,
    public.profile_photos,
    public.profile_prompts,
    public.swipes,
    public.matchmaking_queue,
    public.matches
to anon, authenticated, service_role;

-- Future tables: match the platform's default so a new table created by a
-- later migration does not silently reintroduce the same gap. Live has these
-- defaults for both postgres and supabase_admin; set them for whichever role
-- is running this migration, plus postgres explicitly when it exists.
alter default privileges in schema public
    grant select, insert, update, delete on tables
    to anon, authenticated, service_role;

do $$
begin
    if exists (select 1 from pg_roles where rolname = 'postgres') then
        execute 'alter default privileges for role postgres in schema public '
             || 'grant select, insert, update, delete on tables '
             || 'to anon, authenticated, service_role';
    end if;
end
$$;
