-- Phase 5 (Slice 1): matchmaking queue + Decision Panel data.
--
-- The matchmaker works a queue of live users (M/F alternating). For the pinned
-- user, candidates are MUTUAL likes — people who liked the pinned user and whom
-- the pinned user also liked. Skip advances the queue without matching. The
-- empty-candidate state uses like-stats (received vs given) to steer Boost
-- (Phase 10) vs Skip.
--
-- All Decision Panel reads/writes go through security-definer RPCs guarded to
-- staff (matchmaker/admin), so the queue and cross-user swipe joins aren't
-- exposed to regular users.

-- ---------------------------------------------------------------------------
-- Queue table
-- ---------------------------------------------------------------------------
create table public.matchmaking_queue (
    user_id     uuid primary key references public.users(id) on delete cascade,
    gender      public.gender not null,
    status      text not null default 'active' check (status in ('active', 'skipped', 'matched')),
    enqueued_at timestamptz not null default now(),
    skipped_at  timestamptz,
    updated_at  timestamptz not null default now()
);

create index matchmaking_queue_active_idx
    on public.matchmaking_queue (status, gender, enqueued_at);

alter table public.matchmaking_queue enable row level security;

-- Staff may read the queue; all writes go through the security-definer RPCs.
create policy matchmaking_queue_select_staff
    on public.matchmaking_queue for select to authenticated
    using (public.is_matchmaker_or_admin());

-- Enqueue a user when their profile goes live (and backfill existing ones).
create or replace function public.enqueue_live_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    if new.review_state = 'live' then
        insert into public.matchmaking_queue (user_id, gender)
        values (new.id, new.gender)
        on conflict (user_id) do nothing;
    end if;
    return new;
end;
$$;

create trigger profiles_enqueue
    after insert or update of review_state on public.profiles
    for each row execute function public.enqueue_live_profile();

insert into public.matchmaking_queue (user_id, gender)
select id, gender from public.profiles where review_state = 'live'
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------------
-- Decision Panel RPCs (staff-only, security definer)
-- ---------------------------------------------------------------------------

-- Front of the queue, alternating M/F (interleave per-gender rank).
create or replace function public.next_queued_user()
returns uuid language plpgsql security definer set search_path = public as $$
declare result uuid;
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    select user_id into result
    from (
        select user_id, gender,
               row_number() over (partition by gender order by enqueued_at) as rn
        from public.matchmaking_queue
        where status = 'active'
    ) q
    order by rn, gender
    limit 1;
    return result;
end;
$$;

-- Mutual-like candidates for the pinned user (full profile rows; staff sees all).
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
        order by greatest(a.created_at, b.created_at) desc;
end;
$$;

-- Likes received vs given — drives the empty-state Boost/Skip steer.
create or replace function public.matchmaker_like_stats(target uuid)
returns table (received int, given int)
language plpgsql security definer set search_path = public as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    return query select
        (select count(*) from public.swipes where to_user = target and action = 'like')::int,
        (select count(*) from public.swipes where from_user = target and action = 'like')::int;
end;
$$;

-- Skip the pinned user — advance the queue without matching.
create or replace function public.skip_queued_user(target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    update public.matchmaking_queue
    set status = 'skipped', skipped_at = now(), updated_at = now()
    where user_id = target;
end;
$$;

revoke execute on function public.next_queued_user() from public, anon;
revoke execute on function public.matchmaker_candidates(uuid) from public, anon;
revoke execute on function public.matchmaker_like_stats(uuid) from public, anon;
revoke execute on function public.skip_queued_user(uuid) from public, anon;
grant execute on function public.next_queued_user() to authenticated;
grant execute on function public.matchmaker_candidates(uuid) to authenticated;
grant execute on function public.matchmaker_like_stats(uuid) to authenticated;
grant execute on function public.skip_queued_user(uuid) to authenticated;
