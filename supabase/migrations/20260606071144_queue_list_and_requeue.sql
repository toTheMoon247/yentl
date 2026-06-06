-- Phase 5 (Slice 1 follow-up): a Queue tab + non-destructive "Next profile".
--
-- queued_profiles() lists the active queue in pin order (M/F alternating) for
-- the Queue tab. requeue_user() replaces skip — "Next profile" moves the user
-- to the back of the queue (revisit later) instead of removing them.

-- List the active queue in pin order (full profile rows; staff sees all).
create or replace function public.queued_profiles()
returns setof public.profiles language plpgsql security definer set search_path = public as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    return query
        select p.*
        from (
            select user_id, gender,
                   row_number() over (partition by gender order by enqueued_at) as rn
            from public.matchmaking_queue
            where status = 'active'
        ) q
        join public.profiles p on p.id = q.user_id
        order by q.rn, q.gender;
end;
$$;

-- "Next profile" — send the pinned user to the back of the queue (non-destructive).
create or replace function public.requeue_user(target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    update public.matchmaking_queue
    set enqueued_at = now(), updated_at = now()
    where user_id = target and status = 'active';
end;
$$;

drop function if exists public.skip_queued_user(uuid);

revoke execute on function public.queued_profiles() from public, anon;
revoke execute on function public.requeue_user(uuid) from public, anon;
grant execute on function public.queued_profiles() to authenticated;
grant execute on function public.requeue_user(uuid) to authenticated;
