-- Dev-only: a dedicated matchmaker (staff) account that can sign in with
-- email + password, for the matchmaker app's DEBUG test-login.
--
-- Why this exists: the matchmaker app only offers Google / Apple sign-in, and
-- the only staff account was a real person's Google account. That made the
-- matchmaker app impossible to drive in an automated or unattended test — and
-- the Decision Panel is where matches are created, so it gates testing of the
-- whole match lifecycle. This gives staff the same password-auth escape hatch
-- the consumer seeds already have via set_seed_passwords.sql.
--
-- Email:    seed-staff-01@yentl.test
-- Password: yentltest   (same as every other seed)
--
-- Deliberately has NO profile row, so it never enters the matchmaking queue and
-- never shows up in discovery — it is staff, not a dater.
--
-- Run in the Supabase Studio SQL editor against DEV. NEVER prod. Idempotent.

insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    -- GoTrue reads these into non-optional strings during login; '' not NULL.
    confirmation_token, recovery_token, email_change,
    email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token
)
-- NB: auth.users has no plain unique constraint on `email` (GoTrue uses a
-- partial index), so ON CONFLICT can't be used — guard with NOT EXISTS.
select
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(),
    'authenticated', 'authenticated',
    'seed-staff-01@yentl.test',
    extensions.crypt('yentltest', extensions.gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
    '', '', '', '', '', '', '', ''
where not exists (
    select 1 from auth.users where email = 'seed-staff-01@yentl.test'
);

-- Promote to matchmaker and mark onboarded, so signing in lands straight in the
-- Decision Panel rather than an onboarding flow.
update public.users
set role                    = 'matchmaker',
    onboarding_completed_at = coalesce(onboarding_completed_at, now()),
    terms_accepted_at       = coalesce(terms_accepted_at, now()),
    age_confirmed_at        = coalesce(age_confirmed_at, now())
where id = (select id from auth.users where email = 'seed-staff-01@yentl.test');
