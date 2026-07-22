-- pgTAP tests for Phase 9 Slice 1: the payments ledger — RLS (own-only reads,
-- staff read-all, no client writes), the store_transaction_id dedup key,
-- is_match_paid() (both-paid semantics, refund flips it back), and the
-- staff-only payment_history_for_user() RPC.
--
-- Run locally with:  supabase test db   (needs the local stack up: supabase start)
--
-- Each scenario sets request.jwt.claims + role = authenticated so statements
-- run under the *caller's* identity. Ledger writes run as the superuser,
-- mirroring how the Edge Functions write with the service role (RLS bypassed).

begin;
select plan(16);

-- ---------------------------------------------------------------------------
-- Fixtures: one matchmaker (M), two matched consumers (A, B), one bystander
-- (C). Inserting into auth.users fires on_auth_user_created, which creates
-- the public.users rows the FKs need. The match is inserted directly as the
-- superuser — payment presupposes a confirmed match, not the create_match RPC.
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
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-0000-0000-000000000001',
   'authenticated', 'authenticated', 'test-mm-p9@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-0000-0000-00000000000a',
   'authenticated', 'authenticated', 'test-a-p9@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-0000-0000-00000000000b',
   'authenticated', 'authenticated', 'test-b-p9@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-0000-0000-00000000000c',
   'authenticated', 'authenticated', 'test-c-p9@yentl.test', '',
   now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
   '', '', '', '', '', '', '', '');

update public.users set role = 'matchmaker'
  where id = 'd0000000-0000-0000-0000-000000000001';

insert into public.matches (id, user_a, user_b, state, a_response, b_response)
values ('d0000000-0000-0000-0000-0000000000f1',
        'd0000000-0000-0000-0000-00000000000a',
        'd0000000-0000-0000-0000-00000000000b',
        'confirmed', 'accepted', 'accepted');

-- Set the caller identity (auth.uid()) for the statements that follow.
create function pg_temp.claims_for(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
                    true);
$$;

-- ===========================================================================
-- Scenario 1: nobody has paid — is_match_paid is false, and it is also false
-- for a match id that does not exist (no row ≠ paid).
-- ===========================================================================
select ok(
  not public.is_match_paid('d0000000-0000-0000-0000-0000000000f1'),
  'is_match_paid is false before anyone pays'
);
select ok(
  not public.is_match_paid('d0000000-0000-0000-0000-0000000000ff'),
  'is_match_paid is false for a nonexistent match'
);

-- ===========================================================================
-- Scenario 2: A pays (service-role write, as record-payment does). One paid,
-- one not — the "one paid, the other ghosted" state — is representable and
-- does NOT unlock.
-- ===========================================================================
insert into public.payments (user_id, match_id, product_id, store_transaction_id)
values ('d0000000-0000-0000-0000-00000000000a',
        'd0000000-0000-0000-0000-0000000000f1',
        'date_fee', 'txn-A-0001');

select ok(
  not public.is_match_paid('d0000000-0000-0000-0000-0000000000f1'),
  'one participant paying is not enough — one-paid-other-ghosted stays unpaid'
);

-- ===========================================================================
-- Scenario 3: the dedup key. Re-inserting the same store transaction id is a
-- unique violation — the replay protection the Edge Functions rely on.
-- ===========================================================================
select throws_ok(
  $$ insert into public.payments (user_id, match_id, store_transaction_id)
     values ('d0000000-0000-0000-0000-00000000000a',
             'd0000000-0000-0000-0000-0000000000f1', 'txn-A-0001') $$,
  '23505', null,
  'a duplicate store_transaction_id is refused (replay/dedup key)'
);

-- ===========================================================================
-- Scenario 4: B pays too — is_match_paid flips to true.
-- ===========================================================================
insert into public.payments (user_id, match_id, product_id, store_transaction_id)
values ('d0000000-0000-0000-0000-00000000000b',
        'd0000000-0000-0000-0000-0000000000f1',
        'date_fee', 'txn-B-0001');

select ok(
  public.is_match_paid('d0000000-0000-0000-0000-0000000000f1'),
  'is_match_paid becomes true once BOTH participants have paid'
);

-- ===========================================================================
-- Scenario 5: RLS. A sees only their own row (and can evaluate is_match_paid
-- despite not seeing B's row); C sees nothing; staff sees both rows; client
-- inserts and updates are refused / no-ops — writes are Edge-Function-only.
-- ===========================================================================
select pg_temp.claims_for('d0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.payments), 1,
  'a participant sees exactly one payments row: their own'
);
select is(
  (select store_transaction_id from public.payments), 'txn-A-0001',
  'and it is their own transaction, not their partner''s'
);
select ok(
  public.is_match_paid('d0000000-0000-0000-0000-0000000000f1'),
  'a participant can still evaluate is_match_paid (security definer sees both rows)'
);
select throws_ok(
  $$ insert into public.payments (user_id, match_id, store_transaction_id)
     values ('d0000000-0000-0000-0000-00000000000a',
             'd0000000-0000-0000-0000-0000000000f1', 'txn-A-0002') $$,
  '42501', null,
  'a client cannot insert payments rows — even their own'
);
-- An update aimed at their own row is silently filtered (no update policy).
update public.payments set status = 'refunded' where store_transaction_id = 'txn-A-0001';
reset role;
select is(
  (select status from public.payments where store_transaction_id = 'txn-A-0001'),
  'paid',
  'a client update of a payments row changes nothing (no update policy)'
);

select pg_temp.claims_for('d0000000-0000-0000-0000-00000000000c');
set local role authenticated;
select is(
  (select count(*)::int from public.payments), 0,
  'a bystander sees no payments rows at all'
);
reset role;

select pg_temp.claims_for('d0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int from public.payments), 2,
  'staff sees every payments row'
);
reset role;

-- ===========================================================================
-- Scenario 6: payment_history_for_user is staff-only and returns the target's
-- rows.
-- ===========================================================================
select pg_temp.claims_for('d0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $$ select * from public.payment_history_for_user('d0000000-0000-0000-0000-00000000000b') $$,
  'P0001', 'not authorized',
  'a consumer cannot read another user''s payment history'
);
reset role;

select pg_temp.claims_for('d0000000-0000-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int
     from public.payment_history_for_user('d0000000-0000-0000-0000-00000000000a')),
  1,
  'staff payment history returns the target user''s payments'
);
reset role;

-- ===========================================================================
-- Scenario 7: a refund (service-role write, as the webhook does) flips the
-- row to 'refunded', stamps updated_at, and is_match_paid drops back to false.
-- ===========================================================================
-- Backdate so the trigger's now() is distinguishable from the insert's.
update public.payments
   set updated_at = now() - interval '1 hour'
 where store_transaction_id = 'txn-B-0001';

update public.payments set status = 'refunded'
 where store_transaction_id = 'txn-B-0001';

select ok(
  (select updated_at = now() from public.payments
    where store_transaction_id = 'txn-B-0001'),
  'the updated_at trigger stamps the refund write'
);
select ok(
  not public.is_match_paid('d0000000-0000-0000-0000-0000000000f1'),
  'a refund flips is_match_paid back to false'
);

select * from finish();
rollback;
