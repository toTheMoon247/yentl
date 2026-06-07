-- Dev-only: give every seeded user a known password so the DEBUG "test account"
-- picker can sign in as them (real email/password auth — real JWT, RLS intact).
--
-- Password for ALL seeded users: yentltest
--
-- Run in the Supabase Studio SQL editor against DEV. pgcrypto lives in the
-- `extensions` schema on Supabase; if you get "function extensions.crypt does
-- not exist", drop the `extensions.` prefixes.

update auth.users
set encrypted_password = extensions.crypt('yentltest', extensions.gen_salt('bf')),
    email_confirmed_at = coalesce(email_confirmed_at, now())
where email like 'seed-%@yentl.test';

-- Mark seeds as onboarded so switching to one lands straight in the app
-- (Discover / Matches) instead of the onboarding flow.
update public.users
set onboarding_completed_at = coalesce(onboarding_completed_at, now()),
    terms_accepted_at       = coalesce(terms_accepted_at, now()),
    age_confirmed_at        = coalesce(age_confirmed_at, now())
where id in (select id from auth.users where email like 'seed-%@yentl.test');
