-- pgTAP tests for Phase 6 Slice 2: configurable match expiry ("ignored =
-- rejected") + asymmetric queue outcomes (whoever ACCEPTED returns to the FRONT
-- of the queue, whoever REJECTED or IGNORED returns to the BACK).
--
-- Run locally with:  supabase test db   (needs the local stack up: supabase start)
--
-- Each scenario sets request.jwt.claims + role = authenticated so the RPCs run
-- under the *caller's* identity — the discipline that catches RLS-class bugs (a
-- test run as the superuser would bypass RLS and pass even when real users fail).
-- System / time-passing steps (backdating expires_at, the expiry sweep) run as
-- the superuser, mirroring how pg_cron calls expire_stale_matches() in prod.
--
-- now() is the transaction timestamp here, so it's constant across the whole
-- file; the front/back assertions compare enqueued_at values relative to it.

begin;
select plan(24);

-- ---------------------------------------------------------------------------
-- Fixtures: one matchmaker (M) + two consumers (A, B). Inserting into
-- auth.users fires on_auth_user_created, which creates the public.users rows;
-- we then promote M and add active queue rows for the two consumers.
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
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-000000000001',
   'authenticated', 'authenticated', 'test-matchmaker@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-00000000000a',
   'authenticated', 'authenticated', 'test-a@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-00000000000b',
   'authenticated', 'authenticated', 'test-b@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', '');

update public.users set role = 'matchmaker'
  where id = 'a0000000-0000-0000-0000-000000000001';

insert into public.matchmaking_queue (user_id, gender, status, enqueued_at)
values
  ('a0000000-0000-0000-0000-00000000000a', 'female', 'active', now()),
  ('a0000000-0000-0000-0000-00000000000b', 'male',   'active', now());

-- Set the caller identity (auth.uid()) for the statements that follow.
create function pg_temp.claims_for(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
                    true);
$$;

-- Clear any matches and return both consumers to a clean active queue between
-- independent scenarios. Run as the superuser (RLS-bypassing maintenance).
create function pg_temp.reset_world() returns void language sql as $$
  delete from public.matches;
  update public.matchmaking_queue
     set status = 'active', enqueued_at = now(), updated_at = now();
$$;

-- ===========================================================================
-- Scenario 1: only staff may create a match.
-- ===========================================================================
select pg_temp.claims_for('a0000000-0000-0000-0000-00000000000a');  -- consumer A
set local role authenticated;
select throws_ok(
  $$ select public.create_match('a0000000-0000-0000-0000-00000000000a',
                                'a0000000-0000-0000-0000-00000000000b') $$,
  'P0001', 'not authorized',
  'a non-staff caller cannot create a match'
);
reset role;

-- ===========================================================================
-- Scenario 2: create + guards + the configurable/clamped expiry window.
-- ===========================================================================
select pg_temp.reset_world();

select pg_temp.claims_for('a0000000-0000-0000-0000-000000000001');  -- matchmaker M
set local role authenticated;
select lives_ok(
  $$ select public.create_match('a0000000-0000-0000-0000-00000000000a',
                                'a0000000-0000-0000-0000-00000000000b') $$,
  'matchmaker creates a match'
);
reset role;

select is((select state::text from public.matches),
          'pending', 'a new match starts pending');
select is((select status from public.matchmaking_queue
             where user_id = 'a0000000-0000-0000-0000-00000000000a'),
          'matched', 'user A leaves the active queue on match');
select is((select status from public.matchmaking_queue
             where user_id = 'a0000000-0000-0000-0000-00000000000b'),
          'matched', 'user B leaves the active queue on match');
select ok(
  (select expires_at from public.matches)
    between now() + interval '23 hours 59 minutes'
        and now() + interval '24 hours 1 minute',
  'default window expires in ~24h'
);

-- A 5s request clamps UP to the 60s floor.
select pg_temp.reset_world();
select pg_temp.claims_for('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.create_match('a0000000-0000-0000-0000-00000000000a',
                           'a0000000-0000-0000-0000-00000000000b', 5);
reset role;
select ok(
  (select expires_at from public.matches)
    between now() + interval '59 seconds' and now() + interval '61 seconds',
  'a too-short window is clamped up to the 60s floor'
);

-- A huge request clamps DOWN to the 7-day ceiling.
select pg_temp.reset_world();
select pg_temp.claims_for('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.create_match('a0000000-0000-0000-0000-00000000000a',
                           'a0000000-0000-0000-0000-00000000000b', 99999999);
reset role;
select ok(
  (select expires_at from public.matches)
    between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour',
  'an over-long window is clamped down to the 7-day ceiling'
);

-- Cannot match a user with themselves.
select pg_temp.reset_world();
select pg_temp.claims_for('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select throws_ok(
  $$ select public.create_match('a0000000-0000-0000-0000-00000000000a',
                                'a0000000-0000-0000-0000-00000000000a') $$,
  'P0001', 'cannot match a user with themselves',
  'a user cannot be matched with themselves'
);
reset role;

-- Cannot create a second pending match for someone already pending.
select pg_temp.reset_world();
select pg_temp.claims_for('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.create_match('a0000000-0000-0000-0000-00000000000a',
                           'a0000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ select public.create_match('a0000000-0000-0000-0000-00000000000a',
                                'a0000000-0000-0000-0000-00000000000b') $$,
  'P0001', 'one of these users already has a pending match',
  'a user with a pending match cannot be matched again'
);
reset role;

-- ===========================================================================
-- Scenario 3: both accept -> confirmed, and the couple stays out of the queue.
-- ===========================================================================
select pg_temp.reset_world();
select pg_temp.claims_for('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.create_match('a0000000-0000-0000-0000-00000000000a',
                           'a0000000-0000-0000-0000-00000000000b');
reset role;

select pg_temp.claims_for('a0000000-0000-0000-0000-00000000000a');  -- A accepts
set local role authenticated;
select public.respond_to_match((select id from public.matches), true);
reset role;

select pg_temp.claims_for('a0000000-0000-0000-0000-00000000000b');  -- B accepts
set local role authenticated;
select public.respond_to_match((select id from public.matches), true);
reset role;

select is((select state::text from public.matches),
          'confirmed', 'both accept -> confirmed');
select is((select status from public.matchmaking_queue
             where user_id = 'a0000000-0000-0000-0000-00000000000a'),
          'matched', 'a confirmed couple stays out of the queue (A)');
select is((select status from public.matchmaking_queue
             where user_id = 'a0000000-0000-0000-0000-00000000000b'),
          'matched', 'a confirmed couple stays out of the queue (B)');

-- ===========================================================================
-- Scenario 4: A accepts, B rejects -> rejected; A to the FRONT, B to the BACK.
-- ===========================================================================
select pg_temp.reset_world();
select pg_temp.claims_for('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.create_match('a0000000-0000-0000-0000-00000000000a',
                           'a0000000-0000-0000-0000-00000000000b');
reset role;

select pg_temp.claims_for('a0000000-0000-0000-0000-00000000000a');  -- A accepts
set local role authenticated;
select public.respond_to_match((select id from public.matches), true);
reset role;

select pg_temp.claims_for('a0000000-0000-0000-0000-00000000000b');  -- B rejects
set local role authenticated;
select public.respond_to_match((select id from public.matches), false);
reset role;

select is((select state::text from public.matches),
          'rejected', 'either side rejects -> rejected');
select ok(
  (select status = 'active' and enqueued_at < now() from public.matchmaking_queue
     where user_id = 'a0000000-0000-0000-0000-00000000000a'),
  'the accepter (A) is returned to the FRONT of the queue'
);
select ok(
  (select status = 'active' from public.matchmaking_queue
     where user_id = 'a0000000-0000-0000-0000-00000000000b')
  and (select enqueued_at from public.matchmaking_queue
         where user_id = 'a0000000-0000-0000-0000-00000000000a')
    < (select enqueued_at from public.matchmaking_queue
         where user_id = 'a0000000-0000-0000-0000-00000000000b'),
  'the rejecter (B) is returned BEHIND the accepter'
);

-- ===========================================================================
-- Scenario 5: A accepts, B ignores, the window passes -> expired ("ignored =
-- rejected"); A to the FRONT, B to the BACK.
-- ===========================================================================
select pg_temp.reset_world();
select pg_temp.claims_for('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.create_match('a0000000-0000-0000-0000-00000000000a',
                           'a0000000-0000-0000-0000-00000000000b');
reset role;

select pg_temp.claims_for('a0000000-0000-0000-0000-00000000000a');  -- A accepts; B silent
set local role authenticated;
select public.respond_to_match((select id from public.matches), true);
reset role;

-- Time passes: backdate the deadline, then run the sweep as the system would.
update public.matches set expires_at = now() - interval '1 minute' where state = 'pending';
select is((select public.expire_stale_matches()), 1, 'the sweep expires one stale match');
select is((select state::text from public.matches),
          'expired', 'an ignored match expires ("ignored = rejected")');
select ok(
  (select status = 'active' and enqueued_at < now() from public.matchmaking_queue
     where user_id = 'a0000000-0000-0000-0000-00000000000a'),
  'on expiry, the accepter (A) goes to the FRONT'
);
select ok(
  (select enqueued_at from public.matchmaking_queue
     where user_id = 'a0000000-0000-0000-0000-00000000000a')
  < (select enqueued_at from public.matchmaking_queue
       where user_id = 'a0000000-0000-0000-0000-00000000000b'),
  'on expiry, the ignorer (B) goes BEHIND the accepter'
);

-- ===========================================================================
-- Scenario 6: a match that hasn't reached its deadline is left untouched.
-- ===========================================================================
select pg_temp.reset_world();
select pg_temp.claims_for('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.create_match('a0000000-0000-0000-0000-00000000000a',
                           'a0000000-0000-0000-0000-00000000000b');
reset role;

select is((select public.expire_stale_matches()), 0,
          'the sweep ignores matches before their deadline');
select is((select state::text from public.matches),
          'pending', 'a not-yet-due match stays pending');

-- ===========================================================================
-- Scenario 7: nobody responds -> both ignored, both go to the BACK (equal).
-- ===========================================================================
select pg_temp.reset_world();
select pg_temp.claims_for('a0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.create_match('a0000000-0000-0000-0000-00000000000a',
                           'a0000000-0000-0000-0000-00000000000b');
reset role;

update public.matches set expires_at = now() - interval '1 minute' where state = 'pending';
select public.expire_stale_matches();

select ok(
  (select bool_and(status = 'active') from public.matchmaking_queue
     where user_id in ('a0000000-0000-0000-0000-00000000000a',
                       'a0000000-0000-0000-0000-00000000000b')),
  'when both ignore, both return to the active queue'
);
select ok(
  (select enqueued_at from public.matchmaking_queue
     where user_id = 'a0000000-0000-0000-0000-00000000000a')
  = (select enqueued_at from public.matchmaking_queue
       where user_id = 'a0000000-0000-0000-0000-00000000000b'),
  'when both ignore, neither jumps ahead of the other'
);

select * from finish();
rollback;
