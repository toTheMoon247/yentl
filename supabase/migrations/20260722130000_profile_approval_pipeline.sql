-- Phase 12 (Slice 1): profile approval pipeline — config flag, moderation
-- storage, and the review-state machine. Backend only; no UI in this slice.
--
-- Decisions (2026-07-22, recorded in docs/implementation-plan.md Phase 12):
--   - AI-clean profiles auto-approve; matchmakers review only FLAGGED ones.
--   - Screening runs in the `screen-profile` Edge Function (OpenAI moderation
--     for text+images, GPT-4o vision for the single-real-face check, plus a
--     contact-info regex detector). This migration is the state machine and
--     storage it writes into.
--
-- SAFETY: approval is OFF by default (`profile_approval_enabled` = false in
-- app_config). While OFF, nothing changes for real users: the consumer app's
-- completion update (which writes review_state = 'live' directly) still takes
-- effect exactly as it did before this migration — the enforcement trigger
-- below is a no-op when the flag is off. A later slice flips the flag ON,
-- after the matchmaker review queue UI exists.
--
-- State machine (see enforce_review_state + the RPCs below):
--
--   approval OFF (today, unchanged):
--     completion (client writes 'live')            -> live
--     apply_ai_verdict(any verdict)                -> live   (screening optional)
--   approval ON:
--     completion (client writes 'live')            -> pending_ai   (coerced)
--     apply_ai_verdict('clean')                    -> live
--     apply_ai_verdict('flagged')                  -> pending_review
--     apply_ai_verdict('error')                    -> state unchanged (retryable)
--   any time (staff only):
--     matchmaker_approve_profile                   -> live
--     matchmaker_reject_profile(reason)            -> rejected

-- ---------------------------------------------------------------------------
-- app_config: minimal key/value config. First key: profile_approval_enabled.
-- Anyone authenticated may read (apps need the flag to route the post-
-- completion UX later); only admins (or the service role, which bypasses RLS)
-- may write. Keys are created by migrations, not by clients.
-- ---------------------------------------------------------------------------
create table public.app_config (
    key        text primary key,
    value      jsonb not null,
    updated_at timestamptz not null default now(),
    updated_by uuid references public.users(id)
);

comment on table public.app_config is
  'App-level feature flags/settings. Keys are defined by migrations; values '
  'are flipped by admins or the service role. Readable by any signed-in user.';

create trigger app_config_updated_at
    before update on public.app_config
    for each row execute function public.handle_updated_at();

alter table public.app_config enable row level security;

create policy app_config_select_authenticated
    on public.app_config for select to authenticated
    using (true);

-- Flag flips are an admin action, not a matchmaker one.
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
    select role = 'admin' from public.users where id = auth.uid()
$$;

create policy app_config_update_admin
    on public.app_config for update to authenticated
    using (public.is_admin())
    with check (public.is_admin());

-- No insert/delete policies: the set of keys is schema, managed here.

-- Explicit table grants, per 20260721170000 (RLS is the gate).
grant select, insert, update, delete on table
    public.app_config
to anon, authenticated, service_role;

insert into public.app_config (key, value)
values ('profile_approval_enabled', to_jsonb(false));

-- The single place the flag is read. SECURITY DEFINER + STABLE so triggers
-- and RPCs can evaluate it regardless of the caller's RLS context.
create or replace function public.profile_approval_enabled()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
    select coalesce(
        (select value = to_jsonb(true)
         from public.app_config
         where key = 'profile_approval_enabled'),
        false)
$$;

-- ---------------------------------------------------------------------------
-- profile_moderation: the CURRENT moderation state of a profile — one row per
-- profile (UNIQUE), upserted on every AI screening ("re-screening updates the
-- latest verdict") and carrying the latest matchmaker decision. The full
-- history lives in profile_review_audit below.
--
-- RLS: staff read everything. The OWNER can read their own row — that is what
-- will power the consumer "profile rejected, here's why" screen in a later
-- slice. This is deliberate and safe: reasons/decision_reason describe only
-- the user's OWN content, and decided_by is a bare uuid the consumer cannot
-- resolve to a person (users-table RLS is own-row + staff, and the users
-- table holds no names anyway). No client writes: rows are written only by
-- the SECURITY DEFINER RPCs below / the service role.
-- ---------------------------------------------------------------------------
create table public.profile_moderation (
    id              uuid primary key default gen_random_uuid(),
    profile_id      uuid not null unique references public.profiles(id) on delete cascade,
    verdict         text not null check (verdict in ('clean', 'flagged', 'error')),
    reasons         jsonb not null default '{}'::jsonb,
    created_by      text not null default 'ai' check (created_by in ('ai', 'matchmaker')),
    checked_at      timestamptz not null default now(),
    -- Latest matchmaker decision (null until a human has acted).
    decision        text check (decision in ('approved', 'rejected')),
    decided_by      uuid references public.users(id),
    decided_at      timestamptz,
    decision_reason text
);

comment on table public.profile_moderation is
  'Latest moderation state per profile: newest AI verdict + reasons, plus the '
  'latest matchmaker decision. Upserted by apply_ai_verdict / the matchmaker '
  'RPCs only. History is in profile_review_audit.';

alter table public.profile_moderation enable row level security;

create policy profile_moderation_select_own
    on public.profile_moderation for select to authenticated
    using (auth.uid() = profile_id);

create policy profile_moderation_select_staff
    on public.profile_moderation for select to authenticated
    using (public.is_matchmaker_or_admin());

grant select, insert, update, delete on table
    public.profile_moderation
to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- profile_review_audit: append-only who/when/why trail — one row per AI
-- screening and per matchmaker decision. Staff-only reads: unlike the
-- snapshot above, the trail can contain internal notes across re-reviews and
-- has no consumer-facing purpose. No client writes (definer RPCs only).
-- ---------------------------------------------------------------------------
create table public.profile_review_audit (
    id         uuid primary key default gen_random_uuid(),
    profile_id uuid not null references public.profiles(id) on delete cascade,
    actor      text not null check (actor in ('ai', 'matchmaker')),
    actor_id   uuid references public.users(id),  -- the matchmaker; null for 'ai'
    action     text not null check (action in ('screened', 'approved', 'rejected')),
    verdict    text check (verdict in ('clean', 'flagged', 'error')),
    reason     text,
    details    jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index profile_review_audit_profile_idx
    on public.profile_review_audit (profile_id, created_at desc);

alter table public.profile_review_audit enable row level security;

create policy profile_review_audit_select_staff
    on public.profile_review_audit for select to authenticated
    using (public.is_matchmaker_or_admin());

grant select, insert, update, delete on table
    public.profile_review_audit
to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Enforcement trigger: while approval is ON, nobody reaches 'live' by writing
-- the profiles table directly — a direct attempt becomes a submission for
-- screening ('pending_ai') instead. This is what makes the existing app's
-- completion update (which writes review_state = 'live') do the right thing
-- under BOTH flag values without a client change, and what stops a user from
-- self-approving out of pending_review/rejected.
--
-- The internal RPCs below announce themselves via a transaction-local GUC and
-- pass through untouched. While approval is OFF the trigger is a strict
-- no-op: today's behavior, byte for byte.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_review_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if coalesce(current_setting('yentl.review_state_bypass', true), 'off') = 'on' then
        return new;
    end if;
    if not public.profile_approval_enabled() then
        return new;  -- approval OFF: preserve pre-Phase-12 behavior exactly
    end if;
    if new.review_state = 'live'
       and (tg_op = 'INSERT' or old.review_state is distinct from 'live') then
        new.review_state := 'pending_ai';
    end if;
    return new;
end;
$$;

create trigger profiles_enforce_review_state
    before insert or update on public.profiles
    for each row execute function public.enforce_review_state();

-- ---------------------------------------------------------------------------
-- apply_ai_verdict: the transition the screen-profile Edge Function calls
-- (service role ONLY — no client may execute it; see grants). Records the
-- verdict (snapshot upsert + audit row) and moves review_state per the state
-- machine at the top of this file. A re-screen clears any stale matchmaker
-- decision on the snapshot — it applied to the previous content.
-- ---------------------------------------------------------------------------
create or replace function public.apply_ai_verdict(
    p_profile_id uuid,
    p_verdict    text,
    p_reasons    jsonb default '{}'::jsonb
)
returns public.profile_review_state
language plpgsql
security definer
set search_path = public
as $$
declare
    v_enabled boolean := public.profile_approval_enabled();
    v_state   public.profile_review_state;
begin
    if p_verdict not in ('clean', 'flagged', 'error') then
        raise exception 'invalid verdict: %', p_verdict;
    end if;
    if not exists (select 1 from public.profiles where id = p_profile_id) then
        raise exception 'profile % not found', p_profile_id;
    end if;

    insert into public.profile_moderation
        (profile_id, verdict, reasons, created_by, checked_at)
    values
        (p_profile_id, p_verdict, coalesce(p_reasons, '{}'::jsonb), 'ai', now())
    on conflict (profile_id) do update
        set verdict         = excluded.verdict,
            reasons         = excluded.reasons,
            created_by      = 'ai',
            checked_at      = now(),
            decision        = null,
            decided_by      = null,
            decided_at      = null,
            decision_reason = null;

    insert into public.profile_review_audit (profile_id, actor, action, verdict, details)
    values (p_profile_id, 'ai', 'screened', p_verdict, coalesce(p_reasons, '{}'::jsonb));

    if not v_enabled then
        v_state := 'live';            -- approval OFF: profiles go live, as today
    elsif p_verdict = 'clean' then
        v_state := 'live';            -- AI-clean auto-approves
    elsif p_verdict = 'flagged' then
        v_state := 'pending_review';  -- humans review only flagged profiles
    else
        -- 'error': screening failed — leave the state alone so a retry can
        -- land later; the verdict/audit rows above still record the failure.
        select review_state into v_state from public.profiles where id = p_profile_id;
        return v_state;
    end if;

    perform set_config('yentl.review_state_bypass', 'on', true);
    update public.profiles set review_state = v_state where id = p_profile_id;
    perform set_config('yentl.review_state_bypass', 'off', true);

    -- A profile that is no longer live must not sit in the matchmaking queue
    -- (a re-screen can flag a previously live profile).
    if v_state <> 'live' then
        delete from public.matchmaking_queue where user_id = p_profile_id;
    end if;
    return v_state;
end;
$$;

-- ---------------------------------------------------------------------------
-- Matchmaker decisions (staff-only; the Phase 12 queue UI slice calls these).
-- Approve -> live (which also enqueues via profiles_enqueue). Reject requires
-- a reason -> rejected. Both work regardless of the flag: an explicit staff
-- decision always wins. If no AI screening ever ran (snapshot missing), the
-- snapshot row is created with created_by = 'matchmaker'.
-- ---------------------------------------------------------------------------
create or replace function public.matchmaker_approve_profile(
    target uuid,
    note   text default null
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
    if not exists (select 1 from public.profiles where id = target) then
        raise exception 'profile % not found', target;
    end if;

    insert into public.profile_moderation
        (profile_id, verdict, created_by, decision, decided_by, decided_at, decision_reason)
    values
        (target, 'clean', 'matchmaker', 'approved', auth.uid(), now(), note)
    on conflict (profile_id) do update
        set decision        = 'approved',
            decided_by      = auth.uid(),
            decided_at      = now(),
            decision_reason = note;

    insert into public.profile_review_audit (profile_id, actor, actor_id, action, reason)
    values (target, 'matchmaker', auth.uid(), 'approved', note);

    perform set_config('yentl.review_state_bypass', 'on', true);
    update public.profiles set review_state = 'live' where id = target;
    perform set_config('yentl.review_state_bypass', 'off', true);
end;
$$;

create or replace function public.matchmaker_reject_profile(
    target uuid,
    reason text
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
    if reason is null or btrim(reason) = '' then
        raise exception 'a rejection reason is required';
    end if;
    if not exists (select 1 from public.profiles where id = target) then
        raise exception 'profile % not found', target;
    end if;

    insert into public.profile_moderation
        (profile_id, verdict, created_by, decision, decided_by, decided_at, decision_reason)
    values
        (target, 'flagged', 'matchmaker', 'rejected', auth.uid(), now(), reason)
    on conflict (profile_id) do update
        set decision        = 'rejected',
            decided_by      = auth.uid(),
            decided_at      = now(),
            decision_reason = reason;

    insert into public.profile_review_audit (profile_id, actor, actor_id, action, reason)
    values (target, 'matchmaker', auth.uid(), 'rejected', reason);

    perform set_config('yentl.review_state_bypass', 'on', true);
    update public.profiles set review_state = 'rejected' where id = target;
    perform set_config('yentl.review_state_bypass', 'off', true);

    -- A rejected profile must not sit in the matchmaking queue.
    delete from public.matchmaking_queue where user_id = target;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants. apply_ai_verdict is service-role ONLY (the Edge Function's private
-- transition); clients must not be able to hand themselves a 'clean' verdict.
-- The matchmaker RPCs are callable by any authenticated user but guard on
-- staff role internally, like every other staff RPC in this schema.
-- ---------------------------------------------------------------------------
revoke execute on function public.profile_approval_enabled() from public, anon;
revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.apply_ai_verdict(uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function public.matchmaker_approve_profile(uuid, text) from public, anon;
revoke execute on function public.matchmaker_reject_profile(uuid, text) from public, anon;

grant execute on function public.profile_approval_enabled() to authenticated, service_role;
grant execute on function public.is_admin() to authenticated, service_role;
grant execute on function public.apply_ai_verdict(uuid, text, jsonb) to service_role;
grant execute on function public.matchmaker_approve_profile(uuid, text) to authenticated, service_role;
grant execute on function public.matchmaker_reject_profile(uuid, text) to authenticated, service_role;
