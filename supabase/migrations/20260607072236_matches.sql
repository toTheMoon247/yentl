-- Phase 6 (Slice 1): matches — create, view, respond.
--
-- A matchmaker creates a pending match between two mutual-like users. Each side
-- accepts or rejects within 24h; both-accept -> confirmed, either-reject ->
-- rejected. (24h expiry / "ignored = rejected" + the queue-return-to-front
-- outcome logic land in Slice 2.) On creation both users leave the active
-- queue. All writes go through staff/participant-guarded security-definer RPCs.

create type public.match_state as enum ('pending', 'confirmed', 'rejected', 'expired');

create table public.matches (
    id          uuid primary key default gen_random_uuid(),
    user_a      uuid not null references public.users(id) on delete cascade,
    user_b      uuid not null references public.users(id) on delete cascade,
    created_by  uuid references public.users(id) on delete set null,
    state       public.match_state not null default 'pending',
    a_response  text check (a_response is null or a_response in ('accepted', 'rejected')),
    b_response  text check (b_response is null or b_response in ('accepted', 'rejected')),
    created_at  timestamptz not null default now(),
    expires_at  timestamptz not null default now() + interval '24 hours',
    check (user_a <> user_b)
);

create index matches_user_a_idx on public.matches (user_a);
create index matches_user_b_idx on public.matches (user_b);
create index matches_state_expiry_idx on public.matches (state, expires_at);

alter table public.matches enable row level security;

-- Participants can read their own matches; staff can read all.
create policy matches_select_participant on public.matches
    for select to authenticated
    using (auth.uid() = user_a or auth.uid() = user_b);
create policy matches_select_staff on public.matches
    for select to authenticated
    using (public.is_matchmaker_or_admin());
-- Writes go through the RPCs below (security definer), so no insert/update policy.

-- ---------------------------------------------------------------------------
-- Create a match (matchmaker). Guards: staff-only, no existing pending match
-- for either user. Removes both from the active queue.
-- ---------------------------------------------------------------------------
create or replace function public.create_match(user_one uuid, user_two uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
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

    insert into public.matches (user_a, user_b, created_by)
    values (user_one, user_two, auth.uid())
    returning id into new_id;

    update public.matchmaking_queue
    set status = 'matched', updated_at = now()
    where user_id in (user_one, user_two);

    return new_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- The caller's matches, joined to the OTHER user's PUBLIC profile fields
-- (so a consumer can see who they matched with — height/income never returned).
-- ---------------------------------------------------------------------------
create or replace function public.my_matches()
returns table (
    match_id           uuid,
    state              public.match_state,
    expires_at_epoch   double precision,
    my_response        text,
    other_id           uuid,
    other_display_name text,
    other_date_of_birth date,
    other_gender       public.gender,
    other_location     text,
    other_bio          text,
    other_interests    text[]
)
language plpgsql security definer set search_path = public as $$
begin
    return query
    select
        m.id,
        m.state,
        extract(epoch from m.expires_at)::double precision,
        case when m.user_a = auth.uid() then m.a_response else m.b_response end,
        other.id, other.display_name, other.date_of_birth, other.gender,
        other.location, other.bio, other.interests
    from public.matches m
    join public.profiles other
        on other.id = case when m.user_a = auth.uid() then m.user_b else m.user_a end
    where m.user_a = auth.uid() or m.user_b = auth.uid()
    order by m.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- A participant accepts/rejects. Recomputes state (both-accept -> confirmed,
-- either-reject -> rejected). Queue outcome handling is Slice 2.
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
    elsif m.a_response = 'accepted' and m.b_response = 'accepted' then
        update public.matches set state = 'confirmed' where id = match;
    end if;
end;
$$;

revoke execute on function public.create_match(uuid, uuid) from public, anon;
revoke execute on function public.my_matches() from public, anon;
revoke execute on function public.respond_to_match(uuid, boolean) from public, anon;
grant execute on function public.create_match(uuid, uuid) to authenticated;
grant execute on function public.my_matches() to authenticated;
grant execute on function public.respond_to_match(uuid, boolean) to authenticated;
