-- pgTAP tests for Phase 8 Slice 3: notification_preferences — defaults on
-- insert, own-row upsert/update under RLS, the updated_at trigger, and RLS
-- refusing every cross-user read or write.
--
-- Run locally with:  supabase test db   (needs the local stack up: supabase start)
--
-- Each scenario sets request.jwt.claims + role = authenticated so statements
-- run under the *caller's* identity — the discipline that catches RLS-class
-- bugs. now() is the transaction timestamp (constant across the file), so the
-- updated_at test backdates as the superuser first, same trick as Slice 3.

begin;
select plan(13);

-- ---------------------------------------------------------------------------
-- Fixtures: two consumers (A, B). Inserting into auth.users fires
-- on_auth_user_created, which creates the public.users rows the FK needs.
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
  ('00000000-0000-0000-0000-000000000000', 'e0000000-0000-0000-0000-00000000000a',
   'authenticated', 'authenticated', 'test-a-p8@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e0000000-0000-0000-0000-00000000000b',
   'authenticated', 'authenticated', 'test-b-p8@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', '');

-- Set the caller identity (auth.uid()) for the statements that follow.
create function pg_temp.claims_for(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
                    true);
$$;

-- B's row exists up front (as the superuser) so A's cross-user tests have a
-- real target. message_pushes=false so an RLS leak would be *visible*.
insert into public.notification_preferences (user_id, match_pushes, message_pushes)
values ('e0000000-0000-0000-0000-00000000000b', true, false);

-- ===========================================================================
-- Scenario 1: A creates their own row the way the app does — an upsert with
-- only user_id — and gets the schema defaults (both ON).
-- ===========================================================================
select pg_temp.claims_for('e0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $$ insert into public.notification_preferences (user_id)
     values ('e0000000-0000-0000-0000-00000000000a')
     on conflict (user_id) do nothing $$,
  'a user can insert their own preferences row'
);
select ok(
  (select match_pushes and message_pushes from public.notification_preferences
    where user_id = 'e0000000-0000-0000-0000-00000000000a'),
  'a bare insert defaults both toggles to ON'
);

-- ===========================================================================
-- Scenario 2: A flips match_pushes off via the app's real write shape (upsert
-- with on conflict do update). The other toggle is untouched, and the
-- updated_at trigger stamps the change.
-- ===========================================================================
reset role;
-- Backdate so the trigger's now() is distinguishable from the insert's.
update public.notification_preferences
   set updated_at = now() - interval '1 hour'
 where user_id = 'e0000000-0000-0000-0000-00000000000a';

select pg_temp.claims_for('e0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $$ insert into public.notification_preferences (user_id, match_pushes, message_pushes)
     values ('e0000000-0000-0000-0000-00000000000a', false, true)
     on conflict (user_id) do update
       set match_pushes = excluded.match_pushes,
           message_pushes = excluded.message_pushes $$,
  'a user can upsert their own row to change a toggle'
);
select ok(
  (select not match_pushes and message_pushes
     from public.notification_preferences
    where user_id = 'e0000000-0000-0000-0000-00000000000a'),
  'the upsert turned match pushes off and left message pushes on'
);
select ok(
  (select updated_at = now() from public.notification_preferences
    where user_id = 'e0000000-0000-0000-0000-00000000000a'),
  'the updated_at trigger stamps the write'
);
select lives_ok(
  $$ update public.notification_preferences set match_pushes = true
      where user_id = 'e0000000-0000-0000-0000-00000000000a' $$,
  'a plain update of the own row also works'
);
reset role;

-- ===========================================================================
-- Scenario 3: RLS. A sees only their own row; B's row (message_pushes=false)
-- is invisible to A; cross-user inserts and updates are refused or no-ops.
-- ===========================================================================
select pg_temp.claims_for('e0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.notification_preferences),
  1, 'a user sees exactly one preferences row: their own'
);
select is(
  (select count(*)::int from public.notification_preferences
    where user_id = 'e0000000-0000-0000-0000-00000000000b'),
  0, 'another user''s preferences are invisible'
);
select throws_ok(
  $$ insert into public.notification_preferences (user_id, match_pushes)
     values ('e0000000-0000-0000-0000-00000000000c', false) $$,
  '42501', null,
  'inserting preferences for someone else is refused'
);
-- An update aimed at B's row is silently filtered by RLS: zero rows touched.
update public.notification_preferences set message_pushes = true
 where user_id = 'e0000000-0000-0000-0000-00000000000b';
reset role;
select ok(
  (select message_pushes = false from public.notification_preferences
    where user_id = 'e0000000-0000-0000-0000-00000000000b'),
  'an update aimed at another user''s row changes nothing'
);

-- B, for their part, sees and owns only their row.
select pg_temp.claims_for('e0000000-0000-0000-0000-00000000000b');
set local role authenticated;
select is(
  (select count(*)::int from public.notification_preferences),
  1, 'the other user likewise sees only their own row'
);
select ok(
  (select not message_pushes from public.notification_preferences
    where user_id = 'e0000000-0000-0000-0000-00000000000b'),
  'and reads their own values, not defaults'
);
reset role;

-- ===========================================================================
-- Scenario 4: the opt-out model — a user with NO row (fixture C was never
-- created here; use a fresh count) simply has no preferences stored. The
-- "no row = both on" rule lives in the readers (notify function, app), so
-- the schema-level assertion is just that nothing auto-creates rows.
-- ===========================================================================
select is(
  (select count(*)::int from public.notification_preferences),
  2, 'no trigger auto-creates preference rows — absence stays the default state'
);

select * from finish();
rollback;
