-- pgTAP tests for Phase 7: block + report — block_match() (participant-only,
-- ends the match, records the block, optional report, idempotent-ish),
-- report_user(), the blocked-matches-are-hidden rule in my_matches(), and the
-- blocks/reports RLS (own rows only; staff read all).
--
-- Run locally with:  supabase test db   (needs the local stack up: supabase start)
--
-- Each scenario sets request.jwt.claims + role = authenticated so the RPCs run
-- under the *caller's* identity — the discipline that catches RLS-class bugs.
-- now() is the transaction timestamp, so it is constant across the whole file;
-- where ordering by created_at matters, the earlier match is backdated as the
-- superuser (same trick as the Slice 3 tests).

begin;
select plan(34);

-- ---------------------------------------------------------------------------
-- Fixtures: one matchmaker (M), two consumers (A, B) and an outsider (C).
-- Inserting into auth.users fires on_auth_user_created, which creates the
-- public.users rows; we then promote M, add profiles for A/B (my_matches joins
-- profiles) and active queue rows so the requeue-on-block outcome is testable.
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
  ('00000000-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-000000000001',
   'authenticated', 'authenticated', 'test-mm-p7@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-00000000000a',
   'authenticated', 'authenticated', 'test-a-p7@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-00000000000b',
   'authenticated', 'authenticated', 'test-b-p7@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-00000000000c',
   'authenticated', 'authenticated', 'test-c-p7@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', '');

update public.users set role = 'matchmaker'
  where id = 'c0000000-0000-0000-0000-000000000001';

insert into public.profiles (id, display_name, date_of_birth, gender, location)
values
  ('c0000000-0000-0000-0000-00000000000a', 'Alice Test', '1995-01-01', 'female', 'Tel Aviv'),
  ('c0000000-0000-0000-0000-00000000000b', 'Bob Test',   '1993-01-01', 'male',   'Haifa');

insert into public.matchmaking_queue (user_id, gender, status, enqueued_at)
values
  ('c0000000-0000-0000-0000-00000000000a', 'female', 'active', now()),
  ('c0000000-0000-0000-0000-00000000000b', 'male',   'active', now());

-- Set the caller identity (auth.uid()) for the statements that follow.
create function pg_temp.claims_for(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
                    true);
$$;

-- Match ids captured as the superuser, readable under any role. Needed because
-- a `(select id from public.matches)` inside a throws_ok block runs under the
-- caller's RLS — a non-participant would see no rows and get the wrong error.
create table pg_temp.match_ids (tag text primary key, id uuid);
grant select on pg_temp.match_ids to public;

-- ===========================================================================
-- Scenario 1: guards. Only a participant can block; a match-tied report must
-- come from a participant about the other participant.
-- ===========================================================================
select pg_temp.claims_for('c0000000-0000-0000-0000-000000000001');  -- matchmaker M
set local role authenticated;
select public.create_match('c0000000-0000-0000-0000-00000000000a',
                           'c0000000-0000-0000-0000-00000000000b');
reset role;
insert into pg_temp.match_ids values ('m1', (select id from public.matches));

select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000c');  -- outsider C
set local role authenticated;
select throws_ok(
  $$ select public.block_match((select id from pg_temp.match_ids where tag = 'm1')) $$,
  'P0001', 'not your match',
  'a non-participant cannot block a match'
);
select throws_ok(
  $$ select public.report_user('c0000000-0000-0000-0000-00000000000a', 'harassment',
                               (select id from pg_temp.match_ids where tag = 'm1')) $$,
  'P0001', 'not your match',
  'a non-participant cannot file a report tied to the match'
);
select throws_ok(
  $$ select public.report_user('c0000000-0000-0000-0000-00000000000c', 'other') $$,
  'P0001', 'cannot report yourself',
  'self-reports are refused'
);
select throws_ok(
  $$ select public.block_match('00000000-0000-0000-0000-0000000000ff') $$,
  'P0001', 'match not found',
  'blocking a nonexistent match errors cleanly'
);
reset role;

-- ===========================================================================
-- Scenario 2: A blocks B (with a reason) on the pending match. The match ends
-- in the terminal blocked state, a block row + report row are recorded, both
-- users return to the queue, and re-blocking is a harmless no-op.
-- ===========================================================================
select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000a');  -- A
set local role authenticated;
select lives_ok(
  $$ select public.block_match((select id from pg_temp.match_ids where tag = 'm1'),
                               'harassment', 'kept insulting me') $$,
  'a participant can block, with a reason and note'
);
reset role;

select ok(
  (select state = 'blocked' and resolved_at is not null from public.matches),
  'blocking flips the match to blocked and stamps resolved_at'
);
select is(
  (select count(*)::int from public.blocks
    where blocker_id = 'c0000000-0000-0000-0000-00000000000a'
      and blocked_id = 'c0000000-0000-0000-0000-00000000000b'
      and match_id = (select id from public.matches)),
  1, 'the block row records who blocked whom on which match'
);
select ok(
  (select reporter_id = 'c0000000-0000-0000-0000-00000000000a'
      and reported_id = 'c0000000-0000-0000-0000-00000000000b'
      and match_id = (select id from public.matches)
      and reason = 'harassment'
      and note = 'kept insulting me'
      and status = 'open'
     from public.reports),
  'blocking with a reason files a report with the right reason, note and open status'
);

select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $$ select public.block_match((select id from pg_temp.match_ids where tag = 'm1')) $$,
  'blocking an already-blocked match does not error'
);
reset role;
select is(
  (select count(*)::int from public.blocks),
  1, 're-blocking does not duplicate the block row'
);

select is(
  (select count(*)::int from public.matchmaking_queue where status = 'matched'),
  0, 'after a block nobody is left stuck in queue status matched'
);
select ok(
  (select bool_and(status = 'active' and enqueued_at = now())
     from public.matchmaking_queue),
  'neither responded before the block, so both rejoin at the back of the queue'
);

select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.my_matches()),
  0, 'the blocker no longer sees the blocked match'
);
reset role;
select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000b');
set local role authenticated;
select is(
  (select count(*)::int from public.my_matches()),
  0, 'the blocked side no longer sees the match either'
);
reset role;

-- ===========================================================================
-- Scenario 3: RLS. Own rows only for consumers; staff read all; direct
-- writes are refused (writes go through the RPCs).
-- ===========================================================================
select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000b');  -- B
set local role authenticated;
select is(
  (select count(*)::int from public.blocks),
  0, 'the blocked user cannot see the block made against them'
);
select is(
  (select count(*)::int from public.reports),
  0, 'a user cannot read a report filed about them'
);
select throws_ok(
  $$ insert into public.blocks (blocker_id, blocked_id)
     values ('c0000000-0000-0000-0000-00000000000b',
             'c0000000-0000-0000-0000-00000000000a') $$,
  '42501', null,
  'direct inserts into blocks are refused — writes go through block_match'
);
select throws_ok(
  $$ insert into public.reports (reporter_id, reported_id, reason)
     values ('c0000000-0000-0000-0000-00000000000b',
             'c0000000-0000-0000-0000-00000000000a', 'other') $$,
  '42501', null,
  'direct inserts into reports are refused — writes go through report_user'
);
reset role;

select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000a');  -- A
set local role authenticated;
select is(
  (select count(*)::int from public.blocks),
  1, 'the blocker sees their own block'
);
select is(
  (select count(*)::int from public.reports),
  1, 'the reporter sees their own report'
);
reset role;

select pg_temp.claims_for('c0000000-0000-0000-0000-000000000001');  -- staff M
set local role authenticated;
select is(
  (select count(*)::int from public.blocks),
  1, 'staff can read all blocks'
);
select is(
  (select count(*)::int from public.reports),
  1, 'staff can read all reports'
);
reset role;

-- ===========================================================================
-- Scenario 4: report_user on its own — tied to the (now ended) match, and
-- with no match at all; canned reasons are enforced.
-- ===========================================================================
select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000b');  -- B reports A back
set local role authenticated;
select ok(
  (select public.report_user('c0000000-0000-0000-0000-00000000000a', 'other',
                             (select id from pg_temp.match_ids where tag = 'm1'),
                             'they blocked me mid-plan') is not null),
  'a participant can report the other participant even after the match ended'
);
select ok(
  (select public.report_user('c0000000-0000-0000-0000-00000000000a', 'spam_scam')
     is not null),
  'a report needs no match'
);
select throws_ok(
  $$ select public.report_user('c0000000-0000-0000-0000-00000000000a', 'nonsense') $$,
  '23514', null,
  'a reason outside the canned list is refused'
);
select throws_ok(
  $$ select public.report_user('c0000000-0000-0000-0000-000000000001', 'other',
                               (select id from pg_temp.match_ids where tag = 'm1')) $$,
  'P0001', 'reported user is not part of this match',
  'a match-tied report must target the other participant'
);
reset role;

select pg_temp.claims_for('c0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int from public.reports),
  3, 'staff see every report filed so far'
);
reset role;

-- ===========================================================================
-- Scenario 5: blocking a CONFIRMED match (the in-chat case). The couple left
-- the queue on confirmation; blocking ends the match and requeues them — the
-- blocker to the back, the other person (who had accepted) to the front.
-- ===========================================================================
-- Backdate match 1 so the two matches have distinct created_at values
-- (now() is constant inside this transaction).
update public.matches set created_at = now() - interval '1 hour';

select pg_temp.claims_for('c0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.create_match('c0000000-0000-0000-0000-00000000000a',
                           'c0000000-0000-0000-0000-00000000000b');
reset role;
insert into pg_temp.match_ids
values ('m2', (select id from public.matches where state = 'pending'));

select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select public.respond_to_match((select id from pg_temp.match_ids where tag = 'm2'), true);
reset role;
select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000b');
set local role authenticated;
select public.respond_to_match((select id from pg_temp.match_ids where tag = 'm2'), true);
reset role;

select is(
  (select state from public.matches order by created_at desc limit 1),
  'confirmed'::public.match_state,
  'sanity: both accepted, the second match is confirmed'
);

select pg_temp.claims_for('c0000000-0000-0000-0000-00000000000b');  -- B blocks from chat
set local role authenticated;
select lives_ok(
  $$ select public.block_match((select id from pg_temp.match_ids where tag = 'm2')) $$,
  'a participant can block a confirmed match (the in-chat case)'
);
reset role;

select is(
  (select state from public.matches order by created_at desc limit 1),
  'blocked'::public.match_state,
  'the confirmed match is now blocked'
);
select is(
  (select count(*)::int from public.blocks
    where blocker_id = 'c0000000-0000-0000-0000-00000000000b'),
  1, 'the reverse-direction block row is recorded'
);
select is(
  (select count(*)::int from public.reports),
  3, 'blocking without a reason files no report'
);
select ok(
  (select status = 'active' and enqueued_at < now() - interval '6 months'
     from public.matchmaking_queue
    where user_id = 'c0000000-0000-0000-0000-00000000000a'),
  'the blocked-but-accepting side returns to the FRONT of the queue'
);
select ok(
  (select status = 'active' and enqueued_at = now()
     from public.matchmaking_queue
    where user_id = 'c0000000-0000-0000-0000-00000000000b'),
  'the blocker returns to the BACK of the queue'
);

select * from finish();
rollback;
