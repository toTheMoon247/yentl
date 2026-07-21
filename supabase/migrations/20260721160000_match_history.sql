-- Phase 6 (Slice 3): match history — per-user history + recent-matches feed.
--
-- The matches table already keeps every match forever (rows are never deleted;
-- state moves pending -> confirmed / rejected / expired), so "match history"
-- is a read problem, not a new table. This migration adds:
--
--   1. matches.resolved_at — when the match left 'pending'. Without it the
--      dashboard can only sort by creation time and history can't show *when*
--      an outcome happened. Maintained by respond_to_match and
--      expire_stale_matches below; backfilled for already-resolved rows.
--   2. match_history_for_user(target) — staff-only RPC: every match a given
--      user was part of, from that user's perspective, with the other
--      participant's name. Backs the matchmaker "Match history view per user".
--   3. recent_matches(limit_count) — staff-only RPC: latest matches across all
--      users, both names. Backs the matchmaker "Recent matches dashboard".
--
-- Consumers get nothing new here: participants already read their own matches
-- via my_matches() / the matches RLS policies, and the implementation plan
-- defines no consumer-side history screen. Both new RPCs are hard-gated on
-- is_matchmaker_or_admin(), matching queued_profiles / matchmaker_candidates.

-- ---------------------------------------------------------------------------
-- 1. resolved_at — when the match left 'pending'. Null while pending.
-- ---------------------------------------------------------------------------
alter table public.matches
    add column if not exists resolved_at timestamptz;

comment on column public.matches.resolved_at is
    'When the match left pending (confirmed/rejected/expired). Null while pending.';

-- Backfill already-resolved rows. Expired rows were flipped by the
-- every-minute cron sweep, so expires_at is accurate to ~1 minute; for
-- rejected/confirmed rows expires_at is only an upper bound, but it is the
-- best information the schema recorded before this column existed.
update public.matches
set resolved_at = expires_at
where state <> 'pending' and resolved_at is null;

-- The dashboard reads newest-first across all users.
create index if not exists matches_created_at_idx
    on public.matches (created_at desc);

-- ---------------------------------------------------------------------------
-- respond_to_match: identical to Slice 2 except the state flips now also
-- stamp resolved_at.
-- ---------------------------------------------------------------------------
create or replace function public.respond_to_match(match uuid, accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare m public.matches;
declare reply text := case when accept then 'accepted' else 'rejected' end;
begin
    select * into m from public.matches where id = match for update;
    if m.id is null then raise exception 'match not found'; end if;
    if auth.uid() <> m.user_a and auth.uid() <> m.user_b then
        raise exception 'not your match';
    end if;
    if m.state <> 'pending' then raise exception 'match already resolved'; end if;

    if auth.uid() = m.user_a then
        update public.matches set a_response = reply where id = match;
    else
        update public.matches set b_response = reply where id = match;
    end if;

    select * into m from public.matches where id = match;
    if m.a_response = 'rejected' or m.b_response = 'rejected' then
        update public.matches set state = 'rejected', resolved_at = now() where id = match;
        perform public.requeue_after_match(m.user_a, coalesce(m.a_response = 'accepted', false));
        perform public.requeue_after_match(m.user_b, coalesce(m.b_response = 'accepted', false));
    elsif m.a_response = 'accepted' and m.b_response = 'accepted' then
        update public.matches set state = 'confirmed', resolved_at = now() where id = match;
    end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- expire_stale_matches: identical to Slice 2 except expiring also stamps
-- resolved_at.
-- ---------------------------------------------------------------------------
create or replace function public.expire_stale_matches()
returns int language plpgsql security definer set search_path = public as $$
declare cnt int;
begin
    with expired as (
        update public.matches
        set state = 'expired', resolved_at = now()
        where state = 'pending' and now() > expires_at
        returning user_a, user_b, a_response, b_response
    ),
    participants as (
        select user_a as uid, coalesce(a_response = 'accepted', false) as accepted from expired
        union all
        select user_b as uid, coalesce(b_response = 'accepted', false) as accepted from expired
    ),
    reactivated as (
        update public.matchmaking_queue q
        set status = 'active',
            enqueued_at = case when p.accepted then now() - interval '1 year' else now() end,
            updated_at = now()
        from participants p
        where q.user_id = p.uid and q.status = 'matched'
        returning q.user_id
    )
    select count(*) into cnt from expired;
    return cnt;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. match_history_for_user: every match the target user was part of, newest
-- first, from the target's perspective (their response vs the other side's).
-- Staff-only — this crosses user boundaries by design; the matchmaker app can
-- already read full profiles via the staff RLS policies, so only the display
-- name is denormalized here for the list row.
-- ---------------------------------------------------------------------------
create or replace function public.match_history_for_user(target uuid)
returns table (
    match_id           uuid,
    state              public.match_state,
    created_at_epoch   double precision,
    expires_at_epoch   double precision,
    resolved_at_epoch  double precision,
    target_response    text,
    other_response     text,
    other_id           uuid,
    other_display_name text
)
language plpgsql security definer set search_path = public as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    return query
    select
        m.id,
        m.state,
        extract(epoch from m.created_at)::double precision,
        extract(epoch from m.expires_at)::double precision,
        extract(epoch from m.resolved_at)::double precision,
        case when m.user_a = target then m.a_response else m.b_response end,
        case when m.user_a = target then m.b_response else m.a_response end,
        other.id,
        other.display_name
    from public.matches m
    -- LEFT so a participant without a profile row yields a null name rather
    -- than dropping the match from history entirely. History must not lose rows.
    left join public.profiles other
        on other.id = case when m.user_a = target then m.user_b else m.user_a end
    where m.user_a = target or m.user_b = target
    order by m.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. recent_matches: latest matches across all users for the dashboard.
-- limit_count is clamped to [1, 200] (default 50), mirroring the defensive
-- clamp style of create_match's expiry window.
-- ---------------------------------------------------------------------------
create or replace function public.recent_matches(limit_count int default 50)
returns table (
    match_id           uuid,
    state              public.match_state,
    created_at_epoch   double precision,
    expires_at_epoch   double precision,
    resolved_at_epoch  double precision,
    user_a_id          uuid,
    user_a_name        text,
    user_a_response    text,
    user_b_id          uuid,
    user_b_name        text,
    user_b_response    text
)
language plpgsql security definer set search_path = public as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    return query
    select
        m.id,
        m.state,
        extract(epoch from m.created_at)::double precision,
        extract(epoch from m.expires_at)::double precision,
        extract(epoch from m.resolved_at)::double precision,
        pa.id, pa.display_name, m.a_response,
        pb.id, pb.display_name, m.b_response
    from public.matches m
    -- LEFT for the same reason as match_history_for_user: never drop a match.
    left join public.profiles pa on pa.id = m.user_a
    left join public.profiles pb on pb.id = m.user_b
    order by m.created_at desc
    limit least(greatest(coalesce(limit_count, 50), 1), 200);
end;
$$;

revoke execute on function public.match_history_for_user(uuid) from public, anon;
revoke execute on function public.recent_matches(int) from public, anon;
grant execute on function public.match_history_for_user(uuid) to authenticated;
grant execute on function public.recent_matches(int) to authenticated;
