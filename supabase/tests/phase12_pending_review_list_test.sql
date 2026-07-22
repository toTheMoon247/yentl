-- pgTAP tests for Phase 12 Slice 2: pending_review_profiles() — the staff-only
-- read path behind the matchmaker Approvals tab. Only flagged, COMPLETED
-- profiles appear (in-progress wizard drafts share the pending_review column
-- default and must be excluded), newest-flagged first, with the moderation
-- reasons jsonb (empty object when the snapshot row is missing).
--
-- Run locally with:  supabase test db   (needs the local stack up: supabase start)

begin;
select plan(11);

-- ---------------------------------------------------------------------------
-- Fixtures: matchmaker M, consumers A/B (flagged), C (clean), D (draft).
-- Inserting into auth.users fires on_auth_user_created -> public.users rows.
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
  ('f2000000-0000-0000-0000-000000000001'::uuid, 'test-mm-p12s2@yentl.test'),
  ('f2000000-0000-0000-0000-00000000000a'::uuid, 'test-a-p12s2@yentl.test'),
  ('f2000000-0000-0000-0000-00000000000b'::uuid, 'test-b-p12s2@yentl.test'),
  ('f2000000-0000-0000-0000-00000000000c'::uuid, 'test-c-p12s2@yentl.test'),
  ('f2000000-0000-0000-0000-00000000000d'::uuid, 'test-d-p12s2@yentl.test')
) as fixtures(uid, email);

update public.users set role = 'matchmaker'
  where id = 'f2000000-0000-0000-0000-000000000001';

-- Caller identity for the statements that follow.
create function pg_temp.claims_for(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
                    true);
$$;

-- Insert + complete a profile the way the consumer app does (the completion
-- update writes profile_completed_at AND review_state='live').
create function pg_temp.complete_profile_as(p_uid uuid, p_name text, p_gender public.gender)
returns void language plpgsql as $$
begin
  perform pg_temp.claims_for(p_uid);
  set local role authenticated;
  insert into public.profiles (id, display_name, date_of_birth, gender, location)
  values (p_uid, p_name, '1995-01-01', p_gender, 'Tel Aviv');
  update public.profiles
     set profile_completed_at = now(), review_state = 'live'
   where id = p_uid;
  reset role;
end;
$$;

-- Approval ON so completion routes through screening and flags stick.
update public.app_config set value = to_jsonb(true)
 where key = 'profile_approval_enabled';

-- A and B complete and get flagged; C completes clean; D stays a draft
-- (insert only — review_state keeps the 'pending_review' column default and
-- profile_completed_at stays null).
select pg_temp.complete_profile_as('f2000000-0000-0000-0000-00000000000a', 'Ava', 'female');
select public.apply_ai_verdict('f2000000-0000-0000-0000-00000000000a', 'flagged',
    '{"contact_info": {"flagged": true, "matches": [{"kind": "phone", "sample": "054-1234567"}]}}'::jsonb);
select pg_temp.complete_profile_as('f2000000-0000-0000-0000-00000000000b', 'Ben', 'male');
select public.apply_ai_verdict('f2000000-0000-0000-0000-00000000000b', 'flagged',
    '{"photos": [{"photo_id": "00000000-0000-0000-0000-000000000001", "flagged": true}]}'::jsonb);
select pg_temp.complete_profile_as('f2000000-0000-0000-0000-00000000000c', 'Chloe', 'female');
select public.apply_ai_verdict('f2000000-0000-0000-0000-00000000000c', 'clean');

select pg_temp.claims_for('f2000000-0000-0000-0000-00000000000d');
set local role authenticated;
insert into public.profiles (id, display_name, date_of_birth, gender, location)
values ('f2000000-0000-0000-0000-00000000000d', 'Draft Dan', '1995-01-01', 'male', 'Haifa');
reset role;

-- Both flags landed in the same transaction, so checked_at is identical; push
-- A's screening an hour back to make the newest-first ordering observable.
update public.profile_moderation
   set checked_at = now() - interval '1 hour'
 where profile_id = 'f2000000-0000-0000-0000-00000000000a';

-- ---------------------------------------------------------------------------
-- Staff sees exactly the flagged completed profiles, newest first.
-- ---------------------------------------------------------------------------
select pg_temp.claims_for('f2000000-0000-0000-0000-000000000001');
set local role authenticated;

select is(
  (select count(*)::int from public.pending_review_profiles()),
  2,
  'staff sees exactly the two flagged profiles'
);
select is(
  (select array_agg(profile_id) from public.pending_review_profiles()),
  array['f2000000-0000-0000-0000-00000000000b',
        'f2000000-0000-0000-0000-00000000000a']::uuid[],
  'newest-flagged first: B (just now) before A (an hour ago)'
);
select ok(
  not exists (select 1 from public.pending_review_profiles()
               where profile_id = 'f2000000-0000-0000-0000-00000000000c'),
  'a clean (live) profile is not in the queue'
);
select ok(
  not exists (select 1 from public.pending_review_profiles()
               where profile_id = 'f2000000-0000-0000-0000-00000000000d'),
  'an incomplete wizard draft (default pending_review) is not in the queue'
);
select is(
  (select display_name from public.pending_review_profiles()
    where profile_id = 'f2000000-0000-0000-0000-00000000000a'),
  'Ava',
  'the row carries the profile basics for the list'
);
select is(
  (select reasons->'contact_info'->>'flagged' from public.pending_review_profiles()
    where profile_id = 'f2000000-0000-0000-0000-00000000000a'),
  'true',
  'the moderation reasons jsonb is passed through for rendering'
);
select ok(
  (select flagged_at_epoch > 0 from public.pending_review_profiles()
    where profile_id = 'f2000000-0000-0000-0000-00000000000b'),
  'flagged_at_epoch is a positive epoch timestamp'
);
reset role;

-- A pending_review profile whose moderation snapshot vanished still lists,
-- with empty reasons (LEFT JOIN, not INNER).
delete from public.profile_moderation
 where profile_id = 'f2000000-0000-0000-0000-00000000000b';
select pg_temp.claims_for('f2000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select reasons from public.pending_review_profiles()
    where profile_id = 'f2000000-0000-0000-0000-00000000000b'),
  '{}'::jsonb,
  'a missing moderation row degrades to empty reasons, not a dropped profile'
);

-- ---------------------------------------------------------------------------
-- A decision removes the profile from the queue.
-- ---------------------------------------------------------------------------
select public.matchmaker_approve_profile('f2000000-0000-0000-0000-00000000000a',
                                         'Looks fine');
select is(
  (select array_agg(profile_id) from public.pending_review_profiles()),
  array['f2000000-0000-0000-0000-00000000000b']::uuid[],
  'an approved profile leaves the queue'
);
select public.matchmaker_reject_profile('f2000000-0000-0000-0000-00000000000b',
                                        'inappropriate_photos');
select is(
  (select count(*)::int from public.pending_review_profiles()),
  0,
  'a rejected profile leaves the queue too'
);
reset role;

-- ---------------------------------------------------------------------------
-- Consumers cannot list the review queue.
-- ---------------------------------------------------------------------------
select pg_temp.claims_for('f2000000-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $$ select * from public.pending_review_profiles() $$,
  'P0001', 'not authorized',
  'a consumer cannot list pending-review profiles'
);
reset role;

select * from finish();
rollback;
