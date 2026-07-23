-- pgTAP tests for Phase 11 Slice 1: the reports moderation queue +
-- bans/suspensions — staff-only RPC guards, the account-status columns +
-- audit trail, report triage (reviewed/dismissed/actioned), the
-- account_is_blocked definition (lapsed suspension is NOT blocked), and
-- blocked accounts disappearing from discovery + the matchmaking surfaces.
--
-- Run locally with:  supabase test db   (needs the local stack up: supabase start)

begin;
select plan(45);

-- ---------------------------------------------------------------------------
-- Fixtures: matchmaker M, admin E, consumers A/C (male), B/D (female).
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
  ('a1100000-0000-0000-0000-000000000001'::uuid, 'test-mm-p11@yentl.test'),
  ('a1100000-0000-0000-0000-000000000002'::uuid, 'test-admin-p11@yentl.test'),
  ('a1100000-0000-0000-0000-00000000000a'::uuid, 'test-a-p11@yentl.test'),
  ('a1100000-0000-0000-0000-00000000000b'::uuid, 'test-b-p11@yentl.test'),
  ('a1100000-0000-0000-0000-00000000000c'::uuid, 'test-c-p11@yentl.test'),
  ('a1100000-0000-0000-0000-00000000000d'::uuid, 'test-d-p11@yentl.test')
) as fixtures(uid, email);

update public.users set role = 'matchmaker'
  where id = 'a1100000-0000-0000-0000-000000000001';
update public.users set role = 'admin'
  where id = 'a1100000-0000-0000-0000-000000000002';

-- Caller identity for the statements that follow.
create function pg_temp.claims_for(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
                    true);
$$;

-- Insert + complete a profile the way the consumer app does. Approval is OFF
-- by default here, so completion -> live -> enqueued (profiles_enqueue).
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

select pg_temp.complete_profile_as('a1100000-0000-0000-0000-00000000000a', 'Adam', 'male');
select pg_temp.complete_profile_as('a1100000-0000-0000-0000-00000000000b', 'Beth', 'female');
select pg_temp.complete_profile_as('a1100000-0000-0000-0000-00000000000c', 'Carl', 'male');
select pg_temp.complete_profile_as('a1100000-0000-0000-0000-00000000000d', 'Dana', 'female');

-- Reports: A and C both report B (B is the repeat offender), B reports A.
create function pg_temp.report_as(p_reporter uuid, p_reported uuid, p_reason text, p_note text)
returns uuid language plpgsql as $$
declare rid uuid;
begin
  perform pg_temp.claims_for(p_reporter);
  set local role authenticated;
  select public.report_user(p_reported, p_reason, null, p_note) into rid;
  reset role;
  return rid;
end;
$$;

create table pg_temp.ids (name text primary key, id uuid);
-- The throws_ok probes below read this lookup table while running as the
-- authenticated role, so it needs an explicit grant.
grant select on table pg_temp.ids to authenticated;
insert into pg_temp.ids values
  ('a_reports_b', pg_temp.report_as('a1100000-0000-0000-0000-00000000000a',
                                    'a1100000-0000-0000-0000-00000000000b',
                                    'harassment', 'Sent hostile messages.')),
  ('c_reports_b', pg_temp.report_as('a1100000-0000-0000-0000-00000000000c',
                                    'a1100000-0000-0000-0000-00000000000b',
                                    'spam_scam', null)),
  ('b_reports_a', pg_temp.report_as('a1100000-0000-0000-0000-00000000000b',
                                    'a1100000-0000-0000-0000-00000000000a',
                                    'other', 'Profile seems off.'));

-- All three land in one transaction (identical created_at); stagger them so
-- newest-first ordering is observable: b_reports_a newest, a_reports_b oldest.
update public.reports set created_at = now() - interval '2 hours'
 where id = (select id from pg_temp.ids where name = 'a_reports_b');
update public.reports set created_at = now() - interval '1 hour'
 where id = (select id from pg_temp.ids where name = 'c_reports_b');

-- ===========================================================================
-- Scenario 1: every RPC rejects non-staff callers.
-- ===========================================================================
select pg_temp.claims_for('a1100000-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $$ select * from public.moderation_open_reports() $$,
  'P0001', 'not authorized', 'a consumer cannot list the moderation queue');
select throws_ok(
  $$ select public.resolve_report(
       (select id from pg_temp.ids where name = 'b_reports_a'), true) $$,
  'P0001', 'not authorized', 'a consumer cannot resolve reports');
select throws_ok(
  $$ select public.suspend_user('a1100000-0000-0000-0000-00000000000b',
                                now() + interval '1 day', 'nope') $$,
  'P0001', 'not authorized', 'a consumer cannot suspend anyone');
select throws_ok(
  $$ select public.ban_user('a1100000-0000-0000-0000-00000000000b', 'nope') $$,
  'P0001', 'not authorized', 'a consumer cannot ban anyone');
select throws_ok(
  $$ select public.reinstate_user('a1100000-0000-0000-0000-00000000000b') $$,
  'P0001', 'not authorized', 'a consumer cannot reinstate anyone');
reset role;

-- ===========================================================================
-- Scenario 2: the open-reports queue — content, enrichment, ordering.
-- ===========================================================================
select pg_temp.claims_for('a1100000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int from public.moderation_open_reports()),
  3,
  'staff sees all three open reports');
select is(
  (select array_agg(report_id) from public.moderation_open_reports()),
  (select array[
     (select id from pg_temp.ids where name = 'b_reports_a'),
     (select id from pg_temp.ids where name = 'c_reports_b'),
     (select id from pg_temp.ids where name = 'a_reports_b')]),
  'open reports come newest first');
select is(
  (select reports_against_reported from public.moderation_open_reports()
    where report_id = (select id from pg_temp.ids where name = 'a_reports_b')),
  2,
  'reports_against_reported counts ALL reports against the reported user');
select ok(
  (select reporter_display_name = 'Adam'
      and reported_display_name = 'Beth'
      and reported_account_status = 'active'
      and reason = 'harassment'
      and note = 'Sent hostile messages.'
      and created_at_epoch > 0
     from public.moderation_open_reports()
    where report_id = (select id from pg_temp.ids where name = 'a_reports_b')),
  'a row carries names, reason, note, account status and an epoch timestamp');
reset role;

-- ===========================================================================
-- Scenario 3: resolve_report — reviewed vs dismissed, audit rows, no account
-- change, and the report leaving the open queue.
-- ===========================================================================
select pg_temp.claims_for('a1100000-0000-0000-0000-000000000001');
set local role authenticated;
select public.resolve_report(
  (select id from pg_temp.ids where name = 'b_reports_a'), false);
select public.resolve_report(
  (select id from pg_temp.ids where name = 'c_reports_b'), true);
select is(
  (select status from public.reports
    where id = (select id from pg_temp.ids where name = 'b_reports_a')),
  'reviewed', 'resolve_report(dismiss=false) marks the report reviewed');
select is(
  (select status from public.reports
    where id = (select id from pg_temp.ids where name = 'c_reports_b')),
  'dismissed', 'resolve_report(dismiss=true) marks the report dismissed');
select is(
  (select account_status from public.users
    where id = 'a1100000-0000-0000-0000-00000000000a'),
  'active', 'resolving a report does not touch the account');
select ok(
  exists (select 1 from public.moderation_actions
           where action = 'resolve_report'
             and target_id = 'a1100000-0000-0000-0000-00000000000a'
             and actor_id = 'a1100000-0000-0000-0000-000000000001'
             and report_id = (select id from pg_temp.ids where name = 'b_reports_a')),
  'reviewing writes a resolve_report audit row');
select ok(
  exists (select 1 from public.moderation_actions
           where action = 'dismiss_report'
             and target_id = 'a1100000-0000-0000-0000-00000000000b'
             and report_id = (select id from pg_temp.ids where name = 'c_reports_b')),
  'dismissing writes a dismiss_report audit row');
select is(
  (select array_agg(report_id) from public.moderation_open_reports()),
  (select array[(select id from pg_temp.ids where name = 'a_reports_b')]),
  'resolved and dismissed reports leave the open queue');
select throws_ok(
  $$ select public.resolve_report('00000000-0000-0000-0000-0000000000ff', true) $$,
  'P0001', 'report not found', 'resolving an unknown report fails cleanly');
reset role;

-- ===========================================================================
-- Scenario 4: suspend_user — columns, audit, linked report actioned, guards.
-- ===========================================================================
select pg_temp.claims_for('a1100000-0000-0000-0000-000000000001');
set local role authenticated;
select public.suspend_user(
  'a1100000-0000-0000-0000-00000000000b',
  now() + interval '7 days',
  'Repeated harassment reports',
  (select id from pg_temp.ids where name = 'a_reports_b'));
select ok(
  (select account_status = 'suspended'
      and suspended_until > now() + interval '6 days'
      and moderation_reason = 'Repeated harassment reports'
      and status_changed_at is not null
      and status_changed_by = 'a1100000-0000-0000-0000-000000000001'
     from public.users where id = 'a1100000-0000-0000-0000-00000000000b'),
  'suspend_user sets status, until, reason, and the change stamp');
select is(
  (select status from public.reports
    where id = (select id from pg_temp.ids where name = 'a_reports_b')),
  'actioned', 'suspending from a report marks that report actioned');
select ok(
  exists (select 1 from public.moderation_actions
           where action = 'suspend'
             and target_id = 'a1100000-0000-0000-0000-00000000000b'
             and reason = 'Repeated harassment reports'
             and report_id = (select id from pg_temp.ids where name = 'a_reports_b')),
  'suspending writes a suspend audit row');
select is(
  (select count(*)::int from public.moderation_open_reports()),
  0, 'the actioned report leaves the open queue');
select throws_ok(
  $$ select public.suspend_user('a1100000-0000-0000-0000-00000000000c',
                                now() - interval '1 hour', 'backdated') $$,
  'P0001', 'suspension end must be in the future',
  'a suspension cannot end in the past');
select throws_ok(
  $$ select public.suspend_user('a1100000-0000-0000-0000-00000000000c',
                                now() + interval '1 day', '   ') $$,
  'P0001', 'a suspension reason is required',
  'a suspension requires a reason');
select throws_ok(
  $$ select public.suspend_user('a1100000-0000-0000-0000-000000000002',
                                now() + interval '1 day', 'coup attempt') $$,
  'P0001', 'cannot suspend or ban a staff account',
  'staff accounts cannot be suspended');
select throws_ok(
  $$ select public.ban_user('a1100000-0000-0000-0000-000000000001', 'self-ban') $$,
  'P0001', 'cannot suspend or ban a staff account',
  'staff accounts cannot be banned');
select throws_ok(
  $$ select public.ban_user('a1100000-0000-0000-0000-00000000000c',
       'wrong link', (select id from pg_temp.ids where name = 'a_reports_b')) $$,
  'P0001', 'report is not about this user',
  'a linked report must be about the target user');
reset role;

-- ===========================================================================
-- Scenario 5: account_is_blocked — banned + running suspension are blocked;
-- active + lapsed suspension are not.
-- ===========================================================================
select ok(
  public.account_is_blocked('a1100000-0000-0000-0000-00000000000b'),
  'a running suspension is blocked');
select ok(
  not public.account_is_blocked('a1100000-0000-0000-0000-00000000000a'),
  'an active account is not blocked');

-- Lapse B's suspension (as the clock would).
update public.users set suspended_until = now() - interval '1 minute'
 where id = 'a1100000-0000-0000-0000-00000000000b';
select ok(
  not public.account_is_blocked('a1100000-0000-0000-0000-00000000000b'),
  'a LAPSED suspension is not blocked');

select pg_temp.claims_for('a1100000-0000-0000-0000-000000000001');
set local role authenticated;
select public.ban_user('a1100000-0000-0000-0000-00000000000c', 'Fake profile');
reset role;
select ok(
  public.account_is_blocked('a1100000-0000-0000-0000-00000000000c'),
  'a banned account is blocked');
select ok(
  (select account_status = 'banned' and suspended_until is null
      and moderation_reason = 'Fake profile'
     from public.users where id = 'a1100000-0000-0000-0000-00000000000c'),
  'ban_user sets status banned, clears until, keeps the reason');
select ok(
  exists (select 1 from public.moderation_actions
           where action = 'ban'
             and target_id = 'a1100000-0000-0000-0000-00000000000c'),
  'banning writes a ban audit row');

-- ===========================================================================
-- Scenario 6: blocked accounts vanish from discovery + matching surfaces.
-- C (banned, male) must be invisible; A (active, male) stays.
-- ===========================================================================
select pg_temp.claims_for('a1100000-0000-0000-0000-00000000000d');
set local role authenticated;
select is(
  (select array_agg(id) from public.discovery_feed()),
  array['a1100000-0000-0000-0000-00000000000a']::uuid[],
  'discovery excludes the banned user (D sees only A among the men)');
reset role;

-- Mutual likes D<->C would make C a candidate — the ban must filter him out.
insert into public.swipes (from_user, to_user, action) values
  ('a1100000-0000-0000-0000-00000000000d', 'a1100000-0000-0000-0000-00000000000c', 'like'),
  ('a1100000-0000-0000-0000-00000000000c', 'a1100000-0000-0000-0000-00000000000d', 'like');
select pg_temp.claims_for('a1100000-0000-0000-0000-000000000001');
set local role authenticated;
select ok(
  not exists (select 1 from public.matchmaker_candidates(
                'a1100000-0000-0000-0000-00000000000d')
               where id = 'a1100000-0000-0000-0000-00000000000c'),
  'a banned user is not a Decision Panel candidate');
select ok(
  not exists (select 1 from public.queued_profiles()
               where id = 'a1100000-0000-0000-0000-00000000000c'),
  'a banned user is filtered out of the queue listing');
select ok(
  exists (select 1 from public.queued_profiles()
           where id = 'a1100000-0000-0000-0000-00000000000b'),
  'a lapsed suspension resumes matching (B is back in the queue listing)');
select isnt(
  public.next_queued_user(),
  'a1100000-0000-0000-0000-00000000000c'::uuid,
  'next_queued_user never pins a banned user');
select ok(
  exists (select 1 from public.matchmaking_queue
           where user_id = 'a1100000-0000-0000-0000-00000000000c'),
  'the queue row survives the ban (exclusion is a filter, not a deletion)');
reset role;

-- ===========================================================================
-- Scenario 7: reinstate_user.
-- ===========================================================================
select pg_temp.claims_for('a1100000-0000-0000-0000-000000000001');
set local role authenticated;
select public.reinstate_user('a1100000-0000-0000-0000-00000000000c');
select ok(
  (select account_status = 'active' and suspended_until is null
      and moderation_reason is null and status_changed_at is not null
     from public.users where id = 'a1100000-0000-0000-0000-00000000000c'),
  'reinstate_user restores active and clears the moderation columns');
select ok(
  not public.account_is_blocked('a1100000-0000-0000-0000-00000000000c'),
  'a reinstated account is not blocked');
select ok(
  exists (select 1 from public.moderation_actions
           where action = 'reinstate'
             and target_id = 'a1100000-0000-0000-0000-00000000000c'),
  'reinstating writes a reinstate audit row');
select throws_ok(
  $$ select public.reinstate_user('a1100000-0000-0000-0000-00000000000a') $$,
  'P0001', 'account is not suspended or banned',
  'reinstating an active account is refused');
reset role;

-- ===========================================================================
-- Scenario 8: RLS — the owner reads their own status; the audit trail is
-- staff-only and not client-writable.
-- ===========================================================================
select pg_temp.claims_for('a1100000-0000-0000-0000-00000000000b');
set local role authenticated;
select ok(
  (select account_status = 'suspended' and moderation_reason is not null
     from public.users where id = 'a1100000-0000-0000-0000-00000000000b'),
  'the owner can read their own account_status + reason (consumer gate)');
select is(
  (select count(*)::int from public.moderation_actions),
  0, 'a consumer sees no moderation actions at all');
select throws_ok(
  $$ insert into public.moderation_actions (target_id, actor_id, action)
     values ('a1100000-0000-0000-0000-00000000000b',
             'a1100000-0000-0000-0000-00000000000b', 'reinstate') $$,
  '42501', null,
  'a consumer cannot insert moderation actions (no insert policy)');
reset role;

select pg_temp.claims_for('a1100000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int from public.moderation_actions),
  5,  -- resolve + dismiss + suspend + ban + reinstate
  'staff sees the full audit trail');
reset role;

select * from finish();
rollback;
