-- Phase 6 fix: real M/F alternation in the queue.
--
-- The old ordering (`order by rn, gender`) always put a female at the front, so
-- next_queued_user only ever pinned females. Switch the queue to FIFO by
-- enqueued_at: the front is whoever was enqueued longest ago, and "Next profile"
-- (which sets enqueued_at = now()) sends the current user to the back. Combined
-- with interleaved enqueue timestamps, that yields F, M, F, M as you advance.

-- Front of the queue = oldest enqueued active user.
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
    order by enqueued_at, user_id
    limit 1;
    return result;
end;
$$;

-- Queue tab = same FIFO order (so it matches the pin order).
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
        order by q.enqueued_at, q.user_id;
end;
$$;

-- One-time data fix: re-stagger existing active rows so the two genders
-- interleave by enqueued_at (F, M, F, M ...). New live profiles enqueue at
-- now() and simply append.
with interleaved as (
    select user_id,
           row_number() over (order by rn, gender) as seq
    from (
        select user_id, gender,
               row_number() over (partition by gender order by enqueued_at) as rn
        from public.matchmaking_queue
        where status = 'active'
    ) g
)
update public.matchmaking_queue q
set enqueued_at = now() - interval '1 hour' + (i.seq * interval '1 second')
from interleaved i
where q.user_id = i.user_id;
