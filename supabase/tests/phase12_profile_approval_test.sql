-- pgTAP tests for Phase 12 Slice 1: the profile approval pipeline backend —
-- the profile_approval_enabled flag (default OFF preserves today's behavior),
-- the review-state machine (apply_ai_verdict + matchmaker approve/reject),
-- moderation/audit storage, and RLS (own-only moderation reads, staff-only
-- audit, no self-approval, admin-only flag writes).
--
-- Run locally with:  supabase test db   (needs the local stack up: supabase start)
--
-- Each consumer scenario sets request.jwt.claims + role = authenticated so
-- statements run under the *caller's* identity. apply_ai_verdict runs as the
-- superuser, mirroring how the screen-profile Edge Function calls it with the
-- service role.

begin;
select plan(37);

-- ---------------------------------------------------------------------------
-- Fixtures: matchmaker M, admin E, consumers A/B/C/D. Inserting into
-- auth.users fires on_auth_user_created, which creates the public.users rows.
-- ---------------------------------------------------------------------------
insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change,
    email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token
)
select
  '00000000-0000-0000-0000-000000000000', uid,
  'authenticated', 'authenticated', email, '',
  now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
  '', '', '', '', '', '', '', ''
from (values
  ('e0000000-0000-0000-0000-000000000001'::uuid, 'test-mm-p12@yentl.test'),
  ('e0000000-0000-0000-0000-000000000002'::uuid, 'test-admin-p12@yentl.test'),
  ('e0000000-0000-0000-0000-00000000000a'::uuid, 'test-a-p12@yentl.test'),
  ('e0000000-0000-0000-0000-00000000000b'::uuid, 'test-b-p12@yentl.test'),
  ('e0000000-0000-0000-0000-00000000000c'::uuid, 'test-c-p12@yentl.test'),
  ('e0000000-0000-0000-0000-00000000000d'::uuid, 'test-d-p12@yentl.test')
) as fixtures(uid, email);

update public.users set role = 'matchmaker'
  where id = 'e0000000-0000-0000-0000-000000000001';
update public.users set role = 'admin'
  where id = 'e0000000-0000-0000-0000-000000000002';

-- Set the caller identity (auth.uid()) for the statements that follow.
create function pg_temp.claims_for(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
                    true);
$$;

-- Insert + complete a profile exactly the way the consumer app does today:
-- the completion update writes profile_completed_at AND review_state='live'.
create function pg_temp.complete_profile_as(p_uid uuid, p_gender public.gender)
returns void language plpgsql as $$
begin
  perform pg_temp.claims_for(p_uid);
  set local role authenticated;
  insert into public.profiles (id, display_name, date_of_birth, gender, location)
  values (p_uid, 'Test User', '1995-01-01', p_gender, 'Tel Aviv');
  update public.profiles
     set profile_completed_at = now(), review_state = 'live'
   where id = p_uid;
  reset role;
end;
$$;

-- ===========================================================================
-- Scenario 1: approval OFF (the default) — today's behavior is untouched.
-- ===========================================================================
select ok(
  not public.profile_approval_enabled(),
  'profile_approval_enabled defaults to OFF'
);

select pg_temp.complete_profile_as('e0000000-0000-0000-0000-00000000000a', 'male');
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000a'),
  'live',
  'approval OFF: completing a profile makes it live, exactly as today'
);

-- Even a flagged AI verdict forces live while approval is OFF (screening is
-- recorded but must not block anyone before the flag flips).
select is(
  public.apply_ai_verdict('e0000000-0000-0000-0000-00000000000a', 'flagged',
                          '{"text": {"flagged": true}}'::jsonb)::text,
  'live',
  'approval OFF: apply_ai_verdict(flagged) still returns live'
);
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000a'),
  'live',
  'approval OFF: the profile stays live after a flagged verdict'
);
select is(
  (select verdict from public.profile_moderation
    where profile_id = 'e0000000-0000-0000-0000-00000000000a'),
  'flagged',
  'the flagged verdict is still recorded for later review'
);

-- ===========================================================================
-- Scenario 2: flip approval ON (as the service role / migration would).
-- ===========================================================================
update public.app_config set value = to_jsonb(true)
 where key = 'profile_approval_enabled';
select ok(
  public.profile_approval_enabled(),
  'the flag can be flipped ON'
);

-- ===========================================================================
-- Scenario 3: approval ON — completion is coerced into screening.
-- ===========================================================================
select pg_temp.complete_profile_as('e0000000-0000-0000-0000-00000000000b', 'female');
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000b'),
  'pending_ai',
  'approval ON: the app''s completion write of live is coerced to pending_ai'
);

-- Clean verdict -> auto-approved live (+ enqueued).
select is(
  public.apply_ai_verdict('e0000000-0000-0000-0000-00000000000b', 'clean')::text,
  'live',
  'approval ON: a clean AI verdict returns live'
);
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000b'),
  'live',
  'approval ON: clean profile is live'
);
select is(
  (select count(*)::int from public.matchmaking_queue
    where user_id = 'e0000000-0000-0000-0000-00000000000b'),
  1,
  'going live via the state machine still enqueues for matchmaking'
);

-- Flagged verdict -> pending_review, reasons captured.
select pg_temp.complete_profile_as('e0000000-0000-0000-0000-00000000000c', 'male');
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000c'),
  'pending_ai',
  'C completes into pending_ai as well'
);
select is(
  public.apply_ai_verdict('e0000000-0000-0000-0000-00000000000c', 'flagged',
      '{"contact_info": {"flagged": true, "matches": [{"kind": "phone"}]}}'::jsonb)::text,
  'pending_review',
  'approval ON: a flagged AI verdict returns pending_review'
);
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000c'),
  'pending_review',
  'approval ON: flagged profile awaits matchmaker review'
);
select is(
  (select reasons->'contact_info'->>'flagged' from public.profile_moderation
    where profile_id = 'e0000000-0000-0000-0000-00000000000c'),
  'true',
  'the structured reasons are stored with the verdict'
);

-- Error verdict -> recorded, but the state does not move (retryable).
select pg_temp.complete_profile_as('e0000000-0000-0000-0000-00000000000d', 'female');
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000d'),
  'pending_ai',
  'D completes into pending_ai'
);
select is(
  public.apply_ai_verdict('e0000000-0000-0000-0000-00000000000d', 'error',
                          '{"errors": ["upstream 500"]}'::jsonb)::text,
  'pending_ai',
  'an error verdict leaves the state unchanged (screening can be retried)'
);
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000d'),
  'pending_ai',
  'the errored profile still awaits screening'
);
select is(
  (select verdict from public.profile_moderation
    where profile_id = 'e0000000-0000-0000-0000-00000000000d'),
  'error',
  'the error verdict is recorded'
);

-- ===========================================================================
-- Scenario 4: matchmaker decisions.
-- ===========================================================================
select pg_temp.claims_for('e0000000-0000-0000-0000-000000000001');
set local role authenticated;
select public.matchmaker_approve_profile('e0000000-0000-0000-0000-00000000000c',
                                         'False positive — number was a height');
reset role;
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000c'),
  'live',
  'matchmaker approve moves a flagged profile to live'
);
select ok(
  (select decision = 'approved'
      and decided_by = 'e0000000-0000-0000-0000-000000000001'
     from public.profile_moderation
    where profile_id = 'e0000000-0000-0000-0000-00000000000c'),
  'the approval is audited on the snapshot: who and what'
);

select pg_temp.claims_for('e0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int from public.profile_review_audit
    where profile_id = 'e0000000-0000-0000-0000-00000000000c'),
  2,
  'the audit trail has both events for C: AI screening + matchmaker approval'
);
select public.matchmaker_reject_profile('e0000000-0000-0000-0000-00000000000b',
                                        'Photos are not of one person');
reset role;
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000b'),
  'rejected',
  'matchmaker reject moves a profile to rejected'
);
select is(
  (select decision_reason from public.profile_moderation
    where profile_id = 'e0000000-0000-0000-0000-00000000000b'),
  'Photos are not of one person',
  'the rejection reason is stored (consumer "why" screen reads this later)'
);
select is(
  (select count(*)::int from public.matchmaking_queue
    where user_id = 'e0000000-0000-0000-0000-00000000000b'),
  0,
  'a rejected profile is removed from the matchmaking queue'
);

select pg_temp.claims_for('e0000000-0000-0000-0000-000000000001');
set local role authenticated;
select throws_ok(
  $$ select public.matchmaker_reject_profile('e0000000-0000-0000-0000-00000000000d', '  ') $$,
  'P0001', 'a rejection reason is required',
  'rejecting without a reason is refused'
);
reset role;

-- ===========================================================================
-- Scenario 5: consumers cannot drive the state machine.
-- ===========================================================================
select pg_temp.claims_for('e0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $$ select public.matchmaker_approve_profile('e0000000-0000-0000-0000-00000000000c', null) $$,
  'P0001', 'not authorized',
  'a consumer cannot approve profiles'
);
select throws_ok(
  $$ select public.apply_ai_verdict('e0000000-0000-0000-0000-00000000000a', 'clean') $$,
  '42501', null,
  'a consumer cannot execute apply_ai_verdict at all (service role only)'
);
reset role;

-- B (rejected) tries to self-approve by writing live directly — coerced back
-- into screening, never live.
select pg_temp.claims_for('e0000000-0000-0000-0000-00000000000b');
set local role authenticated;
update public.profiles set review_state = 'live'
 where id = 'e0000000-0000-0000-0000-00000000000b';
reset role;
select is(
  (select review_state::text from public.profiles
    where id = 'e0000000-0000-0000-0000-00000000000b'),
  'pending_ai',
  'approval ON: a user writing review_state=live lands in pending_ai, not live'
);

-- ===========================================================================
-- Scenario 6: RLS on moderation + audit.
-- ===========================================================================
select pg_temp.claims_for('e0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.profile_moderation),
  1,
  'a user sees exactly one moderation row'
);
select is(
  (select profile_id from public.profile_moderation),
  'e0000000-0000-0000-0000-00000000000a'::uuid,
  'and it is their own, not anyone else''s'
);
select is(
  (select count(*)::int from public.profile_review_audit),
  0,
  'the audit trail is staff-only — a consumer sees none of it'
);
reset role;

select pg_temp.claims_for('e0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int from public.profile_moderation),
  4,
  'staff sees every moderation row'
);
reset role;

-- ===========================================================================
-- Scenario 7: a re-screen replaces the latest verdict and clears the stale
-- matchmaker decision (it applied to the previous content).
-- ===========================================================================
select public.apply_ai_verdict('e0000000-0000-0000-0000-00000000000c', 'clean');
select ok(
  (select verdict = 'clean' and decision is null and decided_by is null
     from public.profile_moderation
    where profile_id = 'e0000000-0000-0000-0000-00000000000c'),
  're-screening upserts the snapshot and clears the previous human decision'
);

-- ===========================================================================
-- Scenario 8: app_config — readable by everyone signed in, writable only by
-- admins (matchmakers flip profiles, not platform flags).
-- ===========================================================================
select pg_temp.claims_for('e0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.app_config where key = 'profile_approval_enabled'),
  1,
  'any signed-in user can read the flag'
);
update public.app_config set value = to_jsonb(false)
 where key = 'profile_approval_enabled';
reset role;
select ok(
  public.profile_approval_enabled(),
  'a consumer''s attempt to flip the flag changes nothing'
);

select pg_temp.claims_for('e0000000-0000-0000-0000-000000000001');
set local role authenticated;
update public.app_config set value = to_jsonb(false)
 where key = 'profile_approval_enabled';
reset role;
select ok(
  public.profile_approval_enabled(),
  'a matchmaker cannot flip the flag either (admin-only)'
);

select pg_temp.claims_for('e0000000-0000-0000-0000-000000000002');
set local role authenticated;
update public.app_config set value = to_jsonb(false)
 where key = 'profile_approval_enabled';
reset role;
select ok(
  not public.profile_approval_enabled(),
  'an admin can flip the flag'
);

select * from finish();
rollback;
