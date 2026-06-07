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
