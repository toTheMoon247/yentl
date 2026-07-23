-- Phase 11 (Slice 1): reports moderation queue + bans/suspensions.
--
-- Phase 7 built the data model (blocks, reports) and the in-chat block/report
-- actions; nothing consumed the reports and there was no ban/suspend
-- mechanism. This slice adds:
--   1. An account status on public.users (active / suspended / banned).
--   2. An append-only moderation_actions audit table.
--   3. account_is_blocked(): the ONE definition of "this account is locked
--      out" — banned, or suspended with the suspension still running. A
--      lapsed suspension is NOT blocked (the account falls back into the app
--      without staff intervention; reinstate_user just tidies the columns).
--   4. Staff-only RPCs: the open-reports queue read, report triage
--      (resolve/dismiss), suspend, ban, reinstate. Every mutating action
--      writes a moderation_actions row.
--   5. Blocked-account exclusion from matching surfaces: discovery_feed,
--      matchmaker_candidates, next_queued_user, queued_profiles. The
--      exclusion is a FILTER (not a queue-row deletion) so a lapsed
--      suspension resumes matching automatically — deleting the queue row
--      would strand a lapsed-suspension user out of the queue forever.
--
-- The consumer gate reads the caller's own users row (account_status,
-- suspended_until, moderation_reason): covered by the existing
-- users_select_own policy (whole-row SELECT) + the explicit table grants from
-- 20260721170000 — no new policy needed.

-- ---------------------------------------------------------------------------
-- 1. Account status on public.users. Default 'active' backfills every
--    existing row.
-- ---------------------------------------------------------------------------
alter table public.users
    add column account_status text not null default 'active'
        check (account_status in ('active', 'suspended', 'banned')),
    add column suspended_until   timestamptz,
    add column moderation_reason text,
    add column status_changed_at timestamptz,
    add column status_changed_by uuid references public.users(id);

comment on column public.users.account_status is
  'Moderation state: active / suspended / banned. Written only by the '
  'suspend_user / ban_user / reinstate_user RPCs (security definer).';

-- ---------------------------------------------------------------------------
-- 2. moderation_actions — append-only who/did-what/why audit trail. Staff-only
--    reads; NO client writes (rows are written only by the SECURITY DEFINER
--    RPCs below / the service role).
-- ---------------------------------------------------------------------------
create table public.moderation_actions (
    id         uuid primary key default gen_random_uuid(),
    target_id  uuid not null references public.users(id) on delete cascade,
    actor_id   uuid not null references public.users(id),
    action     text not null check (action in (
                   'suspend', 'ban', 'reinstate',
                   'resolve_report', 'dismiss_report')),
    reason     text,
    -- The report the action came from, when there was one. set null (not
    -- cascade): the audit row outlives the report.
    report_id  uuid references public.reports(id) on delete set null,
    created_at timestamptz not null default now()
);

create index moderation_actions_target_idx
    on public.moderation_actions (target_id, created_at desc);

alter table public.moderation_actions enable row level security;

create policy moderation_actions_select_staff
    on public.moderation_actions for select to authenticated
    using (public.is_matchmaker_or_admin());

-- Explicit table grants, per 20260721170000 (RLS is the gate; grants are
-- mirrored broad so local, CI and production behave identically).
grant select, insert, update, delete on table
    public.moderation_actions
to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. account_is_blocked — the single definition of "locked out".
--    banned: always blocked. suspended: blocked only while suspended_until is
--    in the future. A lapsed suspension is NOT blocked.
-- ---------------------------------------------------------------------------
create or replace function public.account_is_blocked(uid uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
    select coalesce(
        (select u.account_status = 'banned'
             or (u.account_status = 'suspended'
                 and u.suspended_until is not null
                 and u.suspended_until > now())
         from public.users u
         where u.id = uid),
        false)
$$;

-- ---------------------------------------------------------------------------
-- 4. moderation_open_reports — the Reports tab read path. Enriched OPEN
--    reports, newest first. Display names come from public.profiles and may
--    be null (a report can exist before/without a profile row — LEFT JOIN so
--    it still lists). reports_against_reported counts ALL reports (any
--    status) against that user — the "3 reports" repeat-offender signal.
--    Epoch-seconds timestamp, same convention as match_history_for_user /
--    pending_review_profiles. match_id is included so the detail screen can
--    say the report came from a match.
-- ---------------------------------------------------------------------------
create or replace function public.moderation_open_reports()
returns table (
    report_id                uuid,
    reason                   text,
    note                     text,
    created_at_epoch         double precision,
    match_id                 uuid,
    reporter_id              uuid,
    reporter_display_name    text,
    reported_id              uuid,
    reported_display_name    text,
    reported_account_status  text,
    reports_against_reported int
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    return query
        select r.id,
               r.reason,
               r.note,
               extract(epoch from r.created_at)::double precision,
               r.match_id,
               r.reporter_id,
               rp.display_name,
               r.reported_id,
               dp.display_name,
               u.account_status,
               (select count(*)::int from public.reports r2
                 where r2.reported_id = r.reported_id)
        from public.reports r
        join public.users u on u.id = r.reported_id
        left join public.profiles rp on rp.id = r.reporter_id
        left join public.profiles dp on dp.id = r.reported_id
        where r.status = 'open'
        order by r.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. resolve_report — close a report WITHOUT touching the account:
--    dismiss=true -> 'dismissed' (nothing wrong), else 'reviewed' (looked at,
--    handled outside the suspend/ban path). Suspending/banning from a report
--    flips it to 'actioned' via suspend_user/ban_user instead.
-- ---------------------------------------------------------------------------
create or replace function public.resolve_report(report_id uuid, dismiss boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    rep public.reports;
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    select * into rep from public.reports where id = report_id for update;
    if rep.id is null then
        raise exception 'report not found';
    end if;

    update public.reports
       set status = case when dismiss then 'dismissed' else 'reviewed' end
     where id = report_id;

    insert into public.moderation_actions (target_id, actor_id, action, report_id)
    values (rep.reported_id, auth.uid(),
            case when dismiss then 'dismiss_report' else 'resolve_report' end,
            report_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Shared guard for suspend/ban: the target must exist and must not be staff.
-- Staff accounts are demoted first (service role) before they can be actioned
-- — that keeps a compromised matchmaker account from freezing out the admins.
-- ---------------------------------------------------------------------------
create or replace function public.assert_moderation_target(target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_role public.user_role;
begin
    select u.role into v_role from public.users u where u.id = target;
    if v_role is null then
        raise exception 'user not found';
    end if;
    if v_role in ('matchmaker', 'admin') then
        raise exception 'cannot suspend or ban a staff account';
    end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Shared: link a report to a suspend/ban — validates it targets the same
-- user, then marks it 'actioned'.
-- ---------------------------------------------------------------------------
create or replace function public.action_linked_report(p_report uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    rep public.reports;
begin
    select * into rep from public.reports where id = p_report for update;
    if rep.id is null then
        raise exception 'report not found';
    end if;
    if rep.reported_id <> target then
        raise exception 'report is not about this user';
    end if;
    update public.reports set status = 'actioned' where id = p_report;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. suspend_user — time-boxed lockout. The consumer gate shows "suspended
--    until <until>"; once `until` passes the account unblocks by itself
--    (account_is_blocked), so nothing has to run at expiry.
-- ---------------------------------------------------------------------------
create or replace function public.suspend_user(
    target uuid, until timestamptz, reason text, report_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    perform public.assert_moderation_target(target);
    if until is null or until <= now() then
        raise exception 'suspension end must be in the future';
    end if;
    if reason is null or btrim(reason) = '' then
        raise exception 'a suspension reason is required';
    end if;

    update public.users
       set account_status    = 'suspended',
           suspended_until   = until,
           moderation_reason = reason,
           status_changed_at = now(),
           status_changed_by = auth.uid()
     where id = target;

    if report_id is not null then
        perform public.action_linked_report(report_id, target);
    end if;

    insert into public.moderation_actions (target_id, actor_id, action, reason, report_id)
    values (target, auth.uid(), 'suspend', reason, report_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. ban_user — permanent lockout (until reinstated).
-- ---------------------------------------------------------------------------
create or replace function public.ban_user(
    target uuid, reason text, report_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    perform public.assert_moderation_target(target);
    if reason is null or btrim(reason) = '' then
        raise exception 'a ban reason is required';
    end if;

    update public.users
       set account_status    = 'banned',
           suspended_until   = null,
           moderation_reason = reason,
           status_changed_at = now(),
           status_changed_by = auth.uid()
     where id = target;

    if report_id is not null then
        perform public.action_linked_report(report_id, target);
    end if;

    insert into public.moderation_actions (target_id, actor_id, action, reason, report_id)
    values (target, auth.uid(), 'ban', reason, report_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. reinstate_user — lift a suspension/ban (also how a lapsed suspension's
--    leftover columns get tidied). Refuses an already-active account so a
--    stray double-tap doesn't spam the audit trail.
-- ---------------------------------------------------------------------------
create or replace function public.reinstate_user(target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_status text;
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    select u.account_status into v_status from public.users u where u.id = target;
    if v_status is null then
        raise exception 'user not found';
    end if;
    if v_status = 'active' then
        raise exception 'account is not suspended or banned';
    end if;

    update public.users
       set account_status    = 'active',
           suspended_until   = null,
           moderation_reason = null,
           status_changed_at = now(),
           status_changed_by = auth.uid()
     where id = target;

    insert into public.moderation_actions (target_id, actor_id, action)
    values (target, auth.uid(), 'reinstate');
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Blocked accounts disappear from every matching surface. Each function
--    below is the latest prior definition + ONE added
--    `not public.account_is_blocked(...)` condition. Filtering (not deleting
--    queue rows) means a lapsed suspension resumes matching by itself.
-- ---------------------------------------------------------------------------

-- From 20260603171739 (consumer discovery feed).
create or replace function public.discovery_feed(limit_count int default 20)
returns table (
    id            uuid,
    display_name  text,
    date_of_birth date,
    gender        public.gender,
    location      text,
    bio           text,
    interests     text[]
)
language sql
security definer
set search_path = public
as $$
    select p.id, p.display_name, p.date_of_birth, p.gender, p.location, p.bio, p.interests
    from public.profiles p
    where p.review_state = 'live'
      and p.profile_completed_at is not null
      and p.id <> auth.uid()
      and p.gender <> (select gender from public.profiles where id = auth.uid())
      and not public.account_is_blocked(p.id)
      and not exists (
          select 1 from public.swipes s
          where s.from_user = auth.uid() and s.to_user = p.id
      )
    order by p.created_at desc
    limit limit_count
$$;

-- From 20260605203625 (Decision Panel mutual-like candidates).
create or replace function public.matchmaker_candidates(pinned uuid)
returns setof public.profiles language plpgsql security definer set search_path = public as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    return query
        select p.*
        from public.swipes a
        join public.swipes b
            on b.from_user = a.to_user and b.to_user = a.from_user and b.action = 'like'
        join public.profiles p on p.id = a.to_user
        where a.from_user = pinned
          and a.action = 'like'
          and p.review_state = 'live'
          and not public.account_is_blocked(p.id)
        order by greatest(a.created_at, b.created_at) desc;
end;
$$;

-- From 20260607123917 (front of the FIFO queue).
create or replace function public.next_queued_user()
returns uuid language plpgsql security definer set search_path = public as $$
declare result uuid;
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    select user_id into result
    from public.matchmaking_queue
    where status = 'active'
      and not public.account_is_blocked(user_id)
    order by enqueued_at, user_id
    limit 1;
    return result;
end;
$$;

-- From 20260607123917 (Queue tab, same order as the pin).
create or replace function public.queued_profiles()
returns setof public.profiles language plpgsql security definer set search_path = public as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    return query
        select p.*
        from public.matchmaking_queue q
        join public.profiles p on p.id = q.user_id
        where q.status = 'active'
          and not public.account_is_blocked(q.user_id)
        order by q.enqueued_at, q.user_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants. The new staff RPCs are callable by any authenticated user but guard
-- on the staff role internally, like every other staff RPC in this schema.
-- The two internal helpers (assert_moderation_target / action_linked_report)
-- are NOT client-callable — they only run inside the definer RPCs.
-- ---------------------------------------------------------------------------
revoke execute on function public.account_is_blocked(uuid) from public, anon;
revoke execute on function public.moderation_open_reports() from public, anon;
revoke execute on function public.resolve_report(uuid, boolean) from public, anon;
revoke execute on function public.suspend_user(uuid, timestamptz, text, uuid) from public, anon;
revoke execute on function public.ban_user(uuid, text, uuid) from public, anon;
revoke execute on function public.reinstate_user(uuid) from public, anon;
revoke execute on function public.assert_moderation_target(uuid)
    from public, anon, authenticated;
revoke execute on function public.action_linked_report(uuid, uuid)
    from public, anon, authenticated;

grant execute on function public.account_is_blocked(uuid) to authenticated, service_role;
grant execute on function public.moderation_open_reports() to authenticated, service_role;
grant execute on function public.resolve_report(uuid, boolean) to authenticated, service_role;
grant execute on function public.suspend_user(uuid, timestamptz, text, uuid)
    to authenticated, service_role;
grant execute on function public.ban_user(uuid, text, uuid) to authenticated, service_role;
grant execute on function public.reinstate_user(uuid) to authenticated, service_role;
grant execute on function public.assert_moderation_target(uuid) to service_role;
grant execute on function public.action_linked_report(uuid, uuid) to service_role;
