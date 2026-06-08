-- Phase 6 (Slice 2): 24h auto-expiry ("ignored = rejected") + queue outcomes.
--
-- - create_match takes a configurable expiry window (seconds), clamped to a sane
--   range, defaulting to 24h. The client passes a short window in Debug builds
--   so the flow is testable without waiting a day (see YentlShared/AppConfig).
-- - A pg_cron sweep flips pending matches past their deadline to 'expired'
--   (silence = rejection) and returns both people to the queue.
-- - When a match ends as rejected or expired, both participants go back to the
--   active queue so they can be matched with someone else. Confirmed matches
--   keep both 'matched' (they're a couple — out of the queue).

-- ---------------------------------------------------------------------------
-- Helper: return a resolved match's two users to the active queue.
-- ---------------------------------------------------------------------------
create or replace function public.return_users_to_queue(uid_a uuid, uid_b uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
    update public.matchmaking_queue
    set status = 'active', enqueued_at = now(), updated_at = now()
    where user_id in (uid_a, uid_b) and status = 'matched';
end;
$$;

-- ---------------------------------------------------------------------------
-- create_match: now takes a configurable expiry window (seconds).
-- Replaces the 2-arg version. PostgREST can still call it with just the two
-- user ids (expires_in_seconds falls back to its default).
-- ---------------------------------------------------------------------------
drop function if exists public.create_match(uuid, uuid);

create or replace function public.create_match(
    user_one uuid, user_two uuid, expires_in_seconds int default 86400
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
    new_id uuid;
    -- Clamp to [1 minute, 7 days] so a bad/missing value can't create a weird
    -- match. Default (and production) is 24h = 86400s.
    ttl int := least(greatest(coalesce(expires_in_seconds, 86400), 60), 604800);
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    if user_one = user_two then
        raise exception 'cannot match a user with themselves';
    end if;
    if exists (
        select 1 from public.matches
        where state = 'pending'
          and (user_a in (user_one, user_two) or user_b in (user_one, user_two))
    ) then
        raise exception 'one of these users already has a pending match';
    end if;

    insert into public.matches (user_a, user_b, created_by, expires_at)
    values (user_one, user_two, auth.uid(), now() + make_interval(secs => ttl))
    returning id into new_id;

    update public.matchmaking_queue
    set status = 'matched', updated_at = now()
    where user_id in (user_one, user_two);

    return new_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- respond_to_match: on a rejection, also return both users to the queue.
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
        update public.matches set state = 'rejected' where id = match;
        perform public.return_users_to_queue(m.user_a, m.user_b);
    elsif m.a_response = 'accepted' and m.b_response = 'accepted' then
        update public.matches set state = 'confirmed' where id = match;
    end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- expire_stale_matches: flip overdue pending matches to 'expired' (ignored =
-- rejected) and return both participants to the queue. Returns how many
-- expired. Called by pg_cron; not exposed to clients.
-- ---------------------------------------------------------------------------
create or replace function public.expire_stale_matches()
returns int language plpgsql security definer set search_path = public as $$
declare cnt int;
begin
    with expired as (
        update public.matches
        set state = 'expired'
        where state = 'pending' and now() > expires_at
        returning user_a, user_b
    ),
    reactivated as (
        update public.matchmaking_queue q
        set status = 'active', enqueued_at = now(), updated_at = now()
        from expired e
        where q.user_id in (e.user_a, e.user_b) and q.status = 'matched'
        returning q.user_id
    )
    select count(*) into cnt from expired;
    return cnt;
end;
$$;

revoke execute on function public.create_match(uuid, uuid, int) from public, anon;
revoke execute on function public.return_users_to_queue(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.expire_stale_matches() from public, anon, authenticated;
grant execute on function public.create_match(uuid, uuid, int) to authenticated;

-- ---------------------------------------------------------------------------
-- Schedule the expiry sweep every minute via pg_cron. Resilient: if pg_cron
-- isn't available on this project the functions above still apply — enable it
-- (Dashboard → Database → Extensions → pg_cron) and re-run just this block.
-- Every-minute granularity catches both the Debug short window and 24h promptly.
-- ---------------------------------------------------------------------------
do $$
begin
    create extension if not exists pg_cron;
    if exists (select 1 from cron.job where jobname = 'expire-stale-matches') then
        perform cron.unschedule('expire-stale-matches');
    end if;
    perform cron.schedule('expire-stale-matches', '* * * * *',
                          'select public.expire_stale_matches();');
exception when others then
    raise notice 'pg_cron not scheduled (%). Enable pg_cron then re-run the cron block.', sqlerrm;
end $$;
