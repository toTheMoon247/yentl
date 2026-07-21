-- Phase 6 (Slice 3): match history.
--
-- Two read-only, staff-guarded views onto the `matches` table:
--
--   * recent_matches()      — the matchmaker dashboard: what has been matched
--                             lately, across everyone, and how it turned out.
--   * user_match_history()  — one person's match record, for the matchmaker
--                             reviewing them in the Decision Panel ("has this
--                             person been matched before, and did it work?").
--
-- The consumer side needs no new RPC: `my_matches` already returns every state
-- ordered newest-first, so the app can split it into active vs. past in the UI.
--
-- Both are security definer because `matches` only exposes participant rows to
-- a normal caller — a matchmaker needs to read rows they are not part of, and
-- to join the *other* participants' profile names. Neither returns the hidden
-- profile columns (height / income), matching my_matches's discipline.

-- ---------------------------------------------------------------------------
-- Recent matches across all users (matchmaker dashboard), newest first.
-- ---------------------------------------------------------------------------
create or replace function public.recent_matches(limit_count int default 50)
returns table (
    match_id         uuid,
    state            public.match_state,
    created_at_epoch double precision,
    expires_at_epoch double precision,
    a_id             uuid,
    a_display_name   text,
    a_response       text,
    b_id             uuid,
    b_display_name   text,
    b_response       text
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
        m.user_a, pa.display_name, m.a_response,
        m.user_b, pb.display_name, m.b_response
    from public.matches m
    join public.profiles pa on pa.id = m.user_a
    join public.profiles pb on pb.id = m.user_b
    order by m.created_at desc
    limit greatest(1, least(coalesce(limit_count, 50), 200));
end;
$$;

-- ---------------------------------------------------------------------------
-- One user's match history, from THEIR perspective (matchmaker view).
-- `their_response` is the target's own answer; `other_response` the partner's.
-- ---------------------------------------------------------------------------
create or replace function public.user_match_history(target uuid)
returns table (
    match_id           uuid,
    state              public.match_state,
    created_at_epoch   double precision,
    expires_at_epoch   double precision,
    their_response     text,
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
        case when m.user_a = target then m.a_response else m.b_response end,
        case when m.user_a = target then m.b_response else m.a_response end,
        other.id,
        other.display_name
    from public.matches m
    join public.profiles other
        on other.id = case when m.user_a = target then m.user_b else m.user_a end
    where m.user_a = target or m.user_b = target
    order by m.created_at desc;
end;
$$;

revoke execute on function public.recent_matches(int) from public, anon;
revoke execute on function public.user_match_history(uuid) from public, anon;
grant execute on function public.recent_matches(int) to authenticated;
grant execute on function public.user_match_history(uuid) to authenticated;
