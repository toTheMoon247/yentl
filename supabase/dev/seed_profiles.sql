-- Dev-only: seed 20 female + 20 male fake "live" profiles for discovery testing.
--
-- Run in the Supabase Studio SQL editor against the DEV project. NEVER prod.
--
-- These profiles have NO photos (real image files can't be faked via SQL), so
-- their discovery cards show a photo placeholder — fine for testing the swipe
-- flow. Everything else (name, age, location, bio, interests) is populated.
--
-- Seeded users have emails like seed-f-01@yentl.test / seed-m-07@yentl.test and
-- never log in — they're just data. To RE-seed, run the cleanup first (below);
-- re-running step 1 without it fails on the unique email constraint.

------------------------------------------------------------------------
-- CLEANUP (uncomment to remove a previous seed; cascades to profiles)
------------------------------------------------------------------------
-- delete from auth.users where email like 'seed-%@yentl.test';

------------------------------------------------------------------------
-- 1) Seed auth users. The on_auth_user_created trigger auto-creates the
--    matching public.users rows.
------------------------------------------------------------------------
insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    -- GoTrue reads these into non-optional strings during login; '' not NULL.
    confirmation_token, recovery_token, email_change,
    email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token
)
select
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(),
    'authenticated', 'authenticated',
    'seed-' || gender || '-' || lpad(n::text, 2, '0') || '@yentl.test',
    '', now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
    '', '', '', '', '', '', '', ''
from (
    select 'f' as gender, generate_series(1, 20) as n
    union all
    select 'm' as gender, generate_series(1, 20) as n
) s;

------------------------------------------------------------------------
-- 2) Seed completed, live profiles for those users.
------------------------------------------------------------------------
insert into public.profiles (
    id, display_name, date_of_birth, gender, location, bio, interests,
    height_cm, income_annual, profile_completed_at, review_state
)
select
    u.id,
    case when split_part(u.email, '-', 2) = 'f' then 'Test Woman ' else 'Test Man ' end
        || split_part(split_part(u.email, '-', 3), '@', 1),
    (current_date - (((22 + floor(random() * 18))::int) * interval '1 year'))::date,
    (case when split_part(u.email, '-', 2) = 'f' then 'female' else 'male' end)::public.gender,
    (array['New York', 'Tel Aviv', 'London', 'Berlin', 'Paris', 'Austin'])[1 + floor(random() * 6)],
    'Hi! I''m a seeded test profile for discovery.',
    (array['Travel', 'Music', 'Coffee', 'Fitness', 'Cooking', 'Hiking'])[1:3],
    case when split_part(u.email, '-', 2) = 'f'
         then 155 + floor(random() * 20)::int
         else 170 + floor(random() * 20)::int end,
    40000 + floor(random() * 110000)::int,
    now(),
    'live'
from auth.users u
where u.email like 'seed-%@yentl.test'
  and not exists (select 1 from public.profiles p where p.id = u.id);
