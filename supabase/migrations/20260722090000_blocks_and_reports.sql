-- Phase 7 (final slice): block + report from within a chat/match.
--
-- Product decisions (2026-07-22, docs/implementation-plan.md Phase 7):
--   - BLOCK ends the match: terminal `blocked` state, chat hidden for BOTH
--     people, messaging stops. It also records a block row — the strong
--     "do not pair these two again" signal matchmakers will act on later.
--     The moderation queue and global re-match prevention are Phase 11;
--     Phase 7 ends only the current match.
--   - REPORT uses canned reasons (harassment, inappropriate_photos,
--     spam_scam, off_platform_contact, other) + an optional free-text note.
--     Reports carry a `status` column so Phase 11 triage has somewhere to go;
--     everything starts 'open'.
--
-- Writes go through security-definer RPCs (block_match / report_user),
-- mirroring the matches convention: a block must also flip the match state
-- and requeue the participants, so a direct table insert would leave the
-- block and the match out of sync. RLS grants read access only.

-- ---------------------------------------------------------------------------
-- 1. New terminal match state. (Safe inside the migration transaction on
--    PG >= 12 as long as nothing in this same transaction *evaluates* the new
--    value — the function bodies below only reference it at call time.)
-- ---------------------------------------------------------------------------
alter type public.match_state add value if not exists 'blocked';

-- ---------------------------------------------------------------------------
-- 2. blocks — who blocked whom, in which match, when.
-- ---------------------------------------------------------------------------
create table public.blocks (
    id          uuid primary key default gen_random_uuid(),
    blocker_id  uuid not null references public.users(id) on delete cascade,
    blocked_id  uuid not null references public.users(id) on delete cascade,
    -- The match the block came from. Nullable so a future non-match block
    -- surface doesn't need a schema change; matches rows are never deleted,
    -- but set null (not cascade) keeps the block if that ever changes.
    match_id    uuid references public.matches(id) on delete set null,
    created_at  timestamptz not null default now(),
    check (blocker_id <> blocked_id),
    -- One live block per direction; re-blocking is a no-op (see block_match).
    unique (blocker_id, blocked_id)
);

create index blocks_blocked_idx on public.blocks (blocked_id);

alter table public.blocks enable row level security;

-- A user sees only blocks THEY made — never who blocked them.
create policy blocks_select_own on public.blocks
    for select to authenticated
    using (auth.uid() = blocker_id);
-- Staff see all blocks (the Phase 11 "do not re-pair" signal).
create policy blocks_select_staff on public.blocks
    for select to authenticated
    using (public.is_matchmaker_or_admin());
-- Writes go through block_match (security definer), so no insert policy.

-- ---------------------------------------------------------------------------
-- 3. reports — reporter, reported, optional match, canned reason, note.
-- ---------------------------------------------------------------------------
create table public.reports (
    id           uuid primary key default gen_random_uuid(),
    reporter_id  uuid not null references public.users(id) on delete cascade,
    reported_id  uuid not null references public.users(id) on delete cascade,
    match_id     uuid references public.matches(id) on delete set null,
    reason       text not null check (reason in (
                     'harassment', 'inappropriate_photos', 'spam_scam',
                     'off_platform_contact', 'other')),
    note         text check (note is null or char_length(note) <= 2000),
    -- Phase 11 triage state. Values are a starting set; Phase 11 owns them.
    status       text not null default 'open' check (status in (
                     'open', 'reviewed', 'dismissed', 'actioned')),
    created_at   timestamptz not null default now(),
    check (reporter_id <> reported_id)
);

create index reports_reported_idx on public.reports (reported_id);
create index reports_status_idx on public.reports (status);

alter table public.reports enable row level security;

-- A user sees only their own reports.
create policy reports_select_own on public.reports
    for select to authenticated
    using (auth.uid() = reporter_id);
-- Staff read all (Phase 11 moderation queue reads from here).
create policy reports_select_staff on public.reports
    for select to authenticated
    using (public.is_matchmaker_or_admin());
-- Writes go through report_user / block_match; Phase 11 adds the staff
-- status-update path (policy or RPC) when triage is built.

-- Explicit table grants, per 20260721170000: RLS is the gate; grants are
-- mirrored broad so local, CI and production behave identically.
grant select, insert, update, delete on table
    public.blocks,
    public.reports
to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. block_match — a participant ends the match by blocking the other person.
--    Mirrors respond_to_match's structure (participant guard, row lock,
--    requeue). Idempotent-ish: blocking an already-blocked/resolved match
--    records the block (and any report) without erroring.
--
--    Queue outcome: the blocker goes to the BACK of the queue (they ended
--    the match); the other person is positioned by their own response, same
--    as a rejection — FRONT if they had accepted, BACK otherwise.
--    requeue_after_match only touches rows still in status 'matched', so
--    this is a no-op for matches that already returned people to the queue.
-- ---------------------------------------------------------------------------
create or replace function public.block_match(
    match uuid, reason text default null, note text default null
)
returns void language plpgsql security definer set search_path = public as $$
declare
    m public.matches;
    other uuid;
    other_accepted boolean;
begin
    select * into m from public.matches where id = match for update;
    if m.id is null then raise exception 'match not found'; end if;
    if auth.uid() <> m.user_a and auth.uid() <> m.user_b then
        raise exception 'not your match';
    end if;

    other := case when m.user_a = auth.uid() then m.user_b else m.user_a end;
    other_accepted := coalesce(
        (case when m.user_a = auth.uid() then m.b_response else m.a_response end)
            = 'accepted',
        false);

    -- Record the block. Re-blocking the same person is a no-op, not an error.
    insert into public.blocks (blocker_id, blocked_id, match_id)
    values (auth.uid(), other, m.id)
    on conflict (blocker_id, blocked_id) do nothing;

    -- Optional report filed in the same gesture.
    if reason is not null then
        insert into public.reports (reporter_id, reported_id, match_id, reason, note)
        values (auth.uid(), other, m.id, reason, note);
    end if;

    -- End the match. Only live states flip; a match that already ended
    -- (blocked/rejected/expired) keeps its state — the block still counts.
    if m.state in ('pending', 'confirmed') then
        update public.matches
        set state = 'blocked', resolved_at = now()
        where id = match;
        perform public.requeue_after_match(auth.uid(), false);
        perform public.requeue_after_match(other, other_accepted);
    end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. report_user — file a report, optionally tied to a match. When a match is
--    given, the caller must be a participant and the reported user the other
--    participant, so a report can't be pinned on an arbitrary match.
-- ---------------------------------------------------------------------------
create or replace function public.report_user(
    reported uuid, reason text, match uuid default null, note text default null
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
    m public.matches;
    new_id uuid;
begin
    if reported = auth.uid() then
        raise exception 'cannot report yourself';
    end if;
    if match is not null then
        select * into m from public.matches where id = match;
        if m.id is null then raise exception 'match not found'; end if;
        if auth.uid() <> m.user_a and auth.uid() <> m.user_b then
            raise exception 'not your match';
        end if;
        if reported <> m.user_a and reported <> m.user_b then
            raise exception 'reported user is not part of this match';
        end if;
    end if;

    insert into public.reports (reporter_id, reported_id, match_id, reason, note)
    values (auth.uid(), reported, match, reason, note)
    returning id into new_id;

    return new_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. my_matches — unchanged except blocked matches are excluded. Blocking
--    hides the match (and with it the chat entry point) from BOTH sides:
--    each side's next refresh simply no longer contains it. The client also
--    uses this as the source of truth for which Stream channels to show.
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
    where (m.user_a = auth.uid() or m.user_b = auth.uid())
      and m.state <> 'blocked'
    order by m.created_at desc;
end;
$$;

revoke execute on function public.block_match(uuid, text, text) from public, anon;
revoke execute on function public.report_user(uuid, text, uuid, text) from public, anon;
grant execute on function public.block_match(uuid, text, text) to authenticated;
grant execute on function public.report_user(uuid, text, uuid, text) to authenticated;
