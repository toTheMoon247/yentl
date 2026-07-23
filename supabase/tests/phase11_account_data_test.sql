-- pgTAP tests for Phase 11 Slice 2: export_my_data (account data rights).
-- Deletion lives in the delete-account Edge Function (service role + auth
-- admin), so it's covered by the live smoke test, not pgTAP.
--
-- Run locally with:  supabase test db   (needs the local stack up)

begin;
select plan(6);

-- Fixture consumer (insert into auth.users fires the trigger -> public.users).
insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change,
    email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token
) values (
    '00000000-0000-0000-0000-000000000000',
    'e1100000-0000-0000-0000-00000000000a',
    'authenticated', 'authenticated', 'export-test@yentl.test', '',
    now(), now(), now(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
    '', '', '', '', '', '', '', ''
);

create function pg_temp.claims_for(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
                    true);
$$;

insert into public.profiles (id, display_name, date_of_birth, gender, location)
values ('e1100000-0000-0000-0000-00000000000a', 'Ecca', '1990-01-01', 'female', 'Haifa');

-- As the user: export returns their own data.
select pg_temp.claims_for('e1100000-0000-0000-0000-00000000000a');
set local role authenticated;

select ok(public.export_my_data() ? 'account', 'export includes an account section');
select ok(public.export_my_data() ? 'profile', 'export includes a profile section');
select is(public.export_my_data()->>'user_id',
          'e1100000-0000-0000-0000-00000000000a',
          'export user_id is the caller');
select is(public.export_my_data()->'profile'->>'display_name', 'Ecca',
          'export carries the caller''s own profile');
select ok((public.export_my_data() ? 'photos')
          and (public.export_my_data() ? 'matches')
          and (public.export_my_data() ? 'payments'),
          'export has photos / matches / payments sections');

reset role;

-- Unauthenticated: no jwt sub -> auth.uid() null -> raises.
select set_config('request.jwt.claims', '', true);
select throws_ok($$ select public.export_my_data() $$,
                 'not authenticated',
                 'export_my_data requires an authenticated caller');

select finish();
rollback;
