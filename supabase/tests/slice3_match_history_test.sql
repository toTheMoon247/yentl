-- pgTAP tests for Phase 6 Slice 3: match history.
--
--   * recent_matches(limit_count) — staff-only dashboard of recent matches.
--   * user_match_history(target)  — staff-only history for one person.
--
-- Run locally with:  supabase test db   (needs the local stack up: supabase start)
--
-- Same discipline as slice2_match_expiry_test.sql: every RPC call runs with
-- request.jwt.claims set and `role = authenticated`, so the functions execute
-- under a real caller identity. A test run as the superuser would bypass RLS
-- and the staff guard, and would pass even if a consumer could read everyone's
-- match history — exactly the bug worth catching here.
--
-- Unlike the Slice 2 fixtures these users need `profiles` rows, because both
-- new functions join profiles to return the other person's display name.

begin;
select plan(16);

-- ---------------------------------------------------------------------------
-- Fixtures: matchmaker M, consumers A / B / C (all with profiles).
-- ---------------------------------------------------------------------------
insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change,
    email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000', 'b0000000-0000-0000-0000-000000000001',
   'authenticated', 'authenticated', 'hist-matchmaker@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'b0000000-0000-0000-0000-00000000000a',
   'authenticated', 'authenticated', 'hist-a@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'b0000000-0000-0000-0000-00000000000b',
   'authenticated', 'authenticated', 'hist-b@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'b0000000-0000-0000-0000-00000000000c',
   'authenticated', 'authenticated', 'hist-c@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', '');

update public.users set role = 'matchmaker'
  where id = 'b0000000-0000-0000-0000-000000000001';

insert into public.profiles (id, display_name, date_of_birth, gender, location)
values
  ('b0000000-0000-0000-0000-00000000000a', 'Ada',  '1995-01-01', 'female', 'Tel Aviv'),
  ('b0000000-0000-0000-0000-00000000000b', 'Ben',  '1993-01-01', 'male',   'Tel Aviv'),
  ('b0000000-0000-0000-0000-00000000000c', 'Cleo', '1996-01-01', 'female', 'Haifa');

create function pg_temp.claims_for(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
                    true);
$$;

-- Two finished matches for A: an older confirmed one with B, a newer expired
-- one with C where A accepted and C ignored. Inserted directly (as the
-- superuser) rather than via create_match, so the states and timestamps are
-- fixed and the ordering assertions are deterministic.
insert into public.matches
    (id, user_a, user_b, created_by, state, a_response, b_response, created_at, expires_at)
values
  ('b0000000-0000-0000-0000-0000000000f1',
   'b0000000-0000-0000-0000-00000000000a', 'b0000000-0000-0000-0000-00000000000b',
   'b0000000-0000-0000-0000-000000000001', 'confirmed', 'accepted', 'accepted',
   now() - interval '2 days', now() - interval '1 day'),
  ('b0000000-0000-0000-0000-0000000000f2',
   'b0000000-0000-0000-0000-00000000000c', 'b0000000-0000-0000-0000-00000000000a',
   'b0000000-0000-0000-0000-000000000001', 'expired', null, 'accepted',
   now() - interval '1 hour', now() - interval '30 minutes');

-- ===========================================================================
-- Scenario 1: both functions are staff-only.
-- ===========================================================================
select pg_temp.claims_for('b0000000-0000-0000-0000-00000000000a');  -- consumer A
set local role authenticated;
select throws_ok(
  $$ select * from public.recent_matches() $$,
  'P0001', 'not authorized',
  'a consumer cannot read the recent-matches dashboard'
);
select throws_ok(
  $$ select * from public.user_match_history('b0000000-0000-0000-0000-00000000000b') $$,
  'P0001', 'not authorized',
  'a consumer cannot read another user''s match history'
);
reset role;

-- A consumer cannot even read their OWN history through the staff RPC — the
-- consumer path is my_matches(), which is scoped to auth.uid().
select pg_temp.claims_for('b0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $$ select * from public.user_match_history('b0000000-0000-0000-0000-00000000000a') $$,
  'P0001', 'not authorized',
  'the staff history RPC is staff-only even for the subject themselves'
);
reset role;

-- ===========================================================================
-- Scenario 2: recent_matches — content, names, ordering, limit.
-- ===========================================================================
select pg_temp.claims_for('b0000000-0000-0000-0000-000000000001');  -- matchmaker
set local role authenticated;

select is((select count(*) from public.recent_matches()), 2::bigint,
          'the dashboard returns every match, not just the caller''s');

select is((select match_id from public.recent_matches() limit 1),
          'b0000000-0000-0000-0000-0000000000f2'::uuid,
          'the dashboard is ordered newest-first');

select is((select a_display_name from public.recent_matches()
             where match_id = 'b0000000-0000-0000-0000-0000000000f1'),
          'Ada', 'the dashboard resolves user_a''s display name');
select is((select b_display_name from public.recent_matches()
             where match_id = 'b0000000-0000-0000-0000-0000000000f1'),
          'Ben', 'the dashboard resolves user_b''s display name');
select is((select state::text from public.recent_matches()
             where match_id = 'b0000000-0000-0000-0000-0000000000f2'),
          'expired', 'the dashboard reports the outcome state');

select is((select count(*) from public.recent_matches(1)), 1::bigint,
          'limit_count caps the number of rows');
select is((select match_id from public.recent_matches(1)),
          'b0000000-0000-0000-0000-0000000000f2'::uuid,
          'a limit keeps the newest rows');
select is((select count(*) from public.recent_matches(0)), 1::bigint,
          'a zero/negative limit is clamped up to 1 rather than returning nothing');

reset role;

-- ===========================================================================
-- Scenario 3: user_match_history — perspective flipping.
--
-- The subject appears as user_b in one match and user_a in the other, so this
-- is where a naive implementation silently returns the wrong person's answer.
-- ===========================================================================
select pg_temp.claims_for('b0000000-0000-0000-0000-000000000001');
set local role authenticated;

select is((select count(*) from
             public.user_match_history('b0000000-0000-0000-0000-00000000000a')),
          2::bigint, 'A''s history includes both of A''s matches');

select is((select other_display_name from
             public.user_match_history('b0000000-0000-0000-0000-00000000000a')
             where match_id = 'b0000000-0000-0000-0000-0000000000f1'),
          'Ben', 'history names the OTHER person when the subject is user_a');
select is((select other_display_name from
             public.user_match_history('b0000000-0000-0000-0000-00000000000a')
             where match_id = 'b0000000-0000-0000-0000-0000000000f2'),
          'Cleo', 'history names the OTHER person when the subject is user_b');

-- In match f2 the subject A is user_b and accepted; Cleo (user_a) ignored.
select is((select their_response from
             public.user_match_history('b0000000-0000-0000-0000-00000000000a')
             where match_id = 'b0000000-0000-0000-0000-0000000000f2'),
          'accepted', 'their_response is the subject''s own answer, not the partner''s');
select is((select other_response from
             public.user_match_history('b0000000-0000-0000-0000-00000000000a')
             where match_id = 'b0000000-0000-0000-0000-0000000000f2'),
          null, 'other_response is null when the partner ignored the match');

select is((select match_id from
             public.user_match_history('b0000000-0000-0000-0000-00000000000a') limit 1),
          'b0000000-0000-0000-0000-0000000000f2'::uuid,
          'history is ordered newest-first');

select is((select count(*) from
             public.user_match_history('b0000000-0000-0000-0000-00000000000b')),
          1::bigint, 'a user with one match sees only that match');

reset role;

select * from finish();
rollback;
