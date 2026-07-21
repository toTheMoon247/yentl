-- pgTAP tests for Phase 6 Slice 3: match history — resolved_at stamping,
-- match_history_for_user() (per-user history, staff-only) and recent_matches()
-- (dashboard feed, staff-only).
--
-- Run locally with:  supabase test db   (needs the local stack up: supabase start)
--
-- Each scenario sets request.jwt.claims + role = authenticated so the RPCs run
-- under the *caller's* identity — the discipline that catches RLS-class bugs.
-- System / time-passing steps (backdating timestamps, the expiry sweep) run as
-- the superuser, mirroring how pg_cron calls expire_stale_matches() in prod.
--
-- now() is the transaction timestamp here, so it's constant across the whole
-- file; where ordering by created_at matters, the earlier match is explicitly
-- backdated as the superuser.

begin;
select plan(21);

-- ---------------------------------------------------------------------------
-- Fixtures: one matchmaker (M) + two consumers (A, B). Inserting into
-- auth.users fires on_auth_user_created, which creates the public.users rows;
-- we then promote M, add profiles (the history RPCs join profiles for display
-- names) and active queue rows for the two consumers.
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
   'authenticated', 'authenticated', 'test-mm-s3@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'b0000000-0000-0000-0000-00000000000a',
   'authenticated', 'authenticated', 'test-a-s3@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'b0000000-0000-0000-0000-00000000000b',
   'authenticated', 'authenticated', 'test-b-s3@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', '');

update public.users set role = 'matchmaker'
  where id = 'b0000000-0000-0000-0000-000000000001';

insert into public.profiles (id, display_name, date_of_birth, gender, location)
values
  ('b0000000-0000-0000-0000-00000000000a', 'Alice Test', '1995-01-01', 'female', 'Tel Aviv'),
  ('b0000000-0000-0000-0000-00000000000b', 'Bob Test',   '1993-01-01', 'male',   'Haifa');

insert into public.matchmaking_queue (user_id, gender, status, enqueued_at)
values
  ('b0000000-0000-0000-0000-00000000000a', 'female', 'active', now()),
  ('b0000000-0000-0000-0000-00000000000b', 'male',   'active', now());

-- Set the caller identity (auth.uid()) for the statements that follow.
create function pg_temp.claims_for(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
                    true);
$$;

-- ===========================================================================
-- Scenario 1: both history RPCs are staff-only.
-- ===========================================================================
select pg_temp.claims_for('b0000000-0000-0000-0000-00000000000a');  -- consumer A
set local role authenticated;
select throws_ok(
  $$ select * from public.match_history_for_user('b0000000-0000-0000-0000-00000000000b') $$,
  'P0001', 'not authorized',
  'a non-staff caller cannot read another user''s match history'
);
select throws_ok(
  $$ select * from public.recent_matches() $$,
  'P0001', 'not authorized',
  'a non-staff caller cannot read the recent-matches feed'
);
-- Not even for themselves: the consumer path is my_matches(), scoped to
-- auth.uid(); the staff RPC stays staff-only regardless of the target.
select throws_ok(
  $$ select * from public.match_history_for_user('b0000000-0000-0000-0000-00000000000a') $$,
  'P0001', 'not authorized',
  'the staff history RPC is staff-only even for the subject themselves'
);
reset role;

-- ===========================================================================
-- Scenario 2: a pending match — visible in history, not yet resolved.
-- ===========================================================================
select pg_temp.claims_for('b0000000-0000-0000-0000-000000000001');  -- matchmaker M
set local role authenticated;
select public.create_match('b0000000-0000-0000-0000-00000000000a',
                           'b0000000-0000-0000-0000-00000000000b');
reset role;

select ok(
  (select resolved_at is null from public.matches),
  'a pending match has no resolved_at'
);

select pg_temp.claims_for('b0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int from public.match_history_for_user('b0000000-0000-0000-0000-00000000000a')),
  1, 'staff sees the match in A''s history'
);
select is(
  (select other_display_name from public.match_history_for_user('b0000000-0000-0000-0000-00000000000a')),
  'Bob Test', 'A''s history shows the OTHER participant''s name'
);
select ok(
  (select target_response is null and other_response is null
     from public.match_history_for_user('b0000000-0000-0000-0000-00000000000a')),
  'no responses recorded yet on a fresh match'
);
reset role;

-- ===========================================================================
-- Scenario 3: A accepts, B rejects -> rejected; resolved_at is stamped and
-- history shows the responses from each side's own perspective.
-- ===========================================================================
select pg_temp.claims_for('b0000000-0000-0000-0000-00000000000a');  -- A accepts
set local role authenticated;
select public.respond_to_match((select id from public.matches), true);
reset role;

select pg_temp.claims_for('b0000000-0000-0000-0000-00000000000b');  -- B rejects
set local role authenticated;
select public.respond_to_match((select id from public.matches), false);
reset role;

select ok(
  (select state = 'rejected' and resolved_at is not null from public.matches),
  'a rejected match is stamped with resolved_at'
);

select pg_temp.claims_for('b0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select target_response from public.match_history_for_user('b0000000-0000-0000-0000-00000000000a')),
  'accepted', 'A''s history: A''s own response is accepted'
);
select is(
  (select other_response from public.match_history_for_user('b0000000-0000-0000-0000-00000000000a')),
  'rejected', 'A''s history: the other side rejected'
);
select is(
  (select target_response from public.match_history_for_user('b0000000-0000-0000-0000-00000000000b')),
  'rejected', 'B''s history mirrors the perspective: B''s own response is rejected'
);
reset role;

-- ===========================================================================
-- Scenario 4: a second match — created the other way round, so A sits on the
-- user_b side this time (exercising the other branch of the perspective
-- CASE). A accepts, B ignores, the match expires: resolved_at is stamped by
-- the sweep, history accumulates and lists newest first, and the responses
-- are still reported from A's own perspective.
-- ===========================================================================
-- Backdate match 1 so the two matches have distinct created_at values
-- (now() is constant inside this transaction).
update public.matches set created_at = now() - interval '1 hour';

select pg_temp.claims_for('b0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.create_match('b0000000-0000-0000-0000-00000000000b',
                           'b0000000-0000-0000-0000-00000000000a');
reset role;

select pg_temp.claims_for('b0000000-0000-0000-0000-00000000000a');  -- A accepts; B silent
set local role authenticated;
select public.respond_to_match(
  (select id from public.matches where state = 'pending'), true);
reset role;

-- Time passes: backdate the deadline, then run the sweep as the system would.
update public.matches set expires_at = now() - interval '1 minute' where state = 'pending';
select public.expire_stale_matches();

select ok(
  (select resolved_at is not null from public.matches where state = 'expired'),
  'the expiry sweep stamps resolved_at'
);

select pg_temp.claims_for('b0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int from public.match_history_for_user('b0000000-0000-0000-0000-00000000000a')),
  2, 'A''s history accumulates both matches'
);
select is(
  (select match_id from public.match_history_for_user('b0000000-0000-0000-0000-00000000000a') limit 1),
  (select id from public.matches where state = 'expired'),
  'history lists the newest match first'
);
-- A is user_b in this match; the flip must still report A's own answer.
select is(
  (select target_response
     from public.match_history_for_user('b0000000-0000-0000-0000-00000000000a') limit 1),
  'accepted', 'perspective holds when the subject is user_b: A''s own response'
);
select is(
  (select other_response
     from public.match_history_for_user('b0000000-0000-0000-0000-00000000000a') limit 1),
  null, 'other_response is null when the partner ignored the match'
);
reset role;

-- ===========================================================================
-- Scenario 5: the recent-matches dashboard feed.
-- ===========================================================================
select pg_temp.claims_for('b0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int from public.recent_matches()),
  2, 'recent_matches returns every match'
);
select is(
  (select match_id from public.recent_matches() limit 1),
  (select id from public.matches where state = 'expired'),
  'recent_matches lists the newest match first'
);
select ok(
  (select user_a_name = 'Bob Test' and user_b_name = 'Alice Test'
     from public.recent_matches() limit 1),
  'recent_matches carries both participants'' names'
);
select is(
  (select count(*)::int from public.recent_matches(1)),
  1, 'limit_count caps the feed'
);
select is(
  (select count(*)::int from public.recent_matches(0)),
  1, 'a zero/negative limit is clamped up to 1 rather than returning nothing'
);
reset role;

select * from finish();
rollback;
