-- Dev-only reset helpers for re-testing flows from a clean state.
--
-- Run these in the Supabase Studio SQL editor against the DEV project.
-- NEVER run against staging/prod — they are destructive.
--
-- These target ALL rows (the dev DB only holds test users), so there's no
-- need to hardcode an email address. Pick the option that matches what you
-- want to re-test, then relaunch the app. None of A/B/C require a re-login
-- except the full wipe (D).

------------------------------------------------------------------------
-- OPTION A — Re-test onboarding (stays logged in)
-- Clears onboarding consent so the onboarding flow shows again next launch.
------------------------------------------------------------------------
update public.users
set terms_accepted_at       = null,
    age_confirmed_at        = null,
    onboarding_completed_at = null;

------------------------------------------------------------------------
-- OPTION B — Re-test the profile wizard (stays logged in)
-- Removes saved profiles so the creation wizard shows again next launch.
-- (Onboarding stays done, so you go straight to the wizard.)
------------------------------------------------------------------------
-- delete from public.profiles;

------------------------------------------------------------------------
-- OPTION C — Re-test onboarding AND the profile wizard together
-- (stays logged in) — the full post-sign-in experience.
------------------------------------------------------------------------
-- update public.users
-- set terms_accepted_at = null, age_confirmed_at = null, onboarding_completed_at = null;
-- delete from public.profiles;

------------------------------------------------------------------------
-- OPTION D — Full wipe (true "brand new user")
-- Deletes every auth user; public.users + public.profiles cascade away too.
-- Forces a fresh Google sign-in next launch. NOTE: this also removes any
-- matchmaker/admin role you promoted, so you'd re-promote afterward.
------------------------------------------------------------------------
-- delete from auth.users;

------------------------------------------------------------------------
-- Handy: see current state of your test users.
------------------------------------------------------------------------
-- select u.id, au.email, u.role,
--        u.onboarding_completed_at,
--        p.display_name, p.profile_completed_at
-- from public.users u
-- join auth.users au on au.id = u.id
-- left join public.profiles p on p.id = u.id
-- order by u.created_at;
