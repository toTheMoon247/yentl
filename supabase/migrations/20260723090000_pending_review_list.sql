-- Phase 12 (Slice 2): the matchmaker Approvals tab needs a staff-only listing
-- of profiles awaiting human review.
--
-- Decision (2026-07-22, docs/implementation-plan.md Phase 12): the approval
-- queue is a dedicated "Approvals" tab in the matchmaker app showing ONLY
-- flagged profiles (review_state = 'pending_review'); AI-clean profiles
-- auto-approve and never appear. This RPC is that tab's read path — the
-- decisions themselves go through matchmaker_approve_profile /
-- matchmaker_reject_profile from Slice 1.
--
-- Returns one row per pending_review profile, newest first (by when the AI
-- flagged it), with the moderation `reasons` jsonb so the client can render
-- both the list row's flag summary and the detail screen's "why was this
-- flagged" panel. profile_moderation is LEFT JOINed defensively: the state
-- machine always writes a snapshot before moving a profile to pending_review,
-- but a missing row must degrade to empty reasons, not drop the profile from
-- the review queue.
--
-- IMPORTANT: `pending_review` is also the profiles.review_state COLUMN
-- DEFAULT (20260603171739), so an in-progress wizard draft sits at
-- 'pending_review' with profile_completed_at IS NULL until the completion
-- update runs. Those drafts are not review work — the queue lists only
-- COMPLETED profiles (profile_completed_at is not null), i.e. ones that went
-- through submission and were flagged by apply_ai_verdict.
--
-- Epoch-seconds timestamps, same convention as match_history_for_user /
-- recent_matches (avoids client-side timestamp parsing edge cases).

create or replace function public.pending_review_profiles()
returns table (
    profile_id         uuid,
    display_name       text,
    date_of_birth      date,
    gender             public.gender,
    location           text,
    flagged_at_epoch   double precision,
    reasons            jsonb
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
        select p.id,
               p.display_name,
               p.date_of_birth,
               p.gender,
               p.location,
               extract(epoch from coalesce(pm.checked_at, p.updated_at))::double precision,
               coalesce(pm.reasons, '{}'::jsonb)
        from public.profiles p
        left join public.profile_moderation pm on pm.profile_id = p.id
        where p.review_state = 'pending_review'
          and p.profile_completed_at is not null
        order by coalesce(pm.checked_at, p.updated_at) desc;
end;
$$;

revoke execute on function public.pending_review_profiles() from public, anon;
grant execute on function public.pending_review_profiles() to authenticated, service_role;
