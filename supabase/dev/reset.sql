-- Dev-only reset helpers for re-testing flows from a clean state.
--
-- Run these in the Supabase Studio SQL editor against the DEV project.
-- NEVER run against staging/prod — they are destructive.
--
-- These target ALL rows (the dev DB only holds test users), so there's no
-- need to hardcode an email address. Pick the option that matches what you
-- want to re-test, then relaunch the app.

------------------------------------------------------------------------
-- OPTION A — Soft reset (fastest; stays logged in)
-- Clears onboarding consent so the onboarding flow shows again on next
-- app launch. You do NOT have to sign in again. Use this for iterating
-- on the onboarding / post-sign-in flow.
------------------------------------------------------------------------
update public.users
set terms_accepted_at       = null,
    age_confirmed_at        = null,
    onboarding_completed_at = null;

------------------------------------------------------------------------
-- OPTION B — Full wipe (true "brand new user")
-- Deletes every auth user; the on_auth_user_created trigger means the
-- matching public.users rows cascade away too. Forces a fresh Google
-- sign-in next launch — use this to re-test first-sign-in + the trigger.
-- (Commented out so it can't run by accident; uncomment to use.)
------------------------------------------------------------------------
-- delete from auth.users;

------------------------------------------------------------------------
-- Handy: see current state of your test users.
------------------------------------------------------------------------
-- select u.id, au.email, u.role,
--        u.onboarding_completed_at, u.terms_accepted_at, u.age_confirmed_at
-- from public.users u
-- join auth.users au on au.id = u.id
-- order by u.created_at;
