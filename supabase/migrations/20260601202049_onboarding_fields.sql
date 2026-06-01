-- Phase 1: Onboarding consent fields on public.users.
--
-- After first Google sign-in, the Yentl consumer app shows a lightweight
-- onboarding flow (welcome + privacy note + terms/consent + 18+ confirmation)
-- before the home screen. The acceptance is tied to the account, not the
-- device, so these columns live on public.users and are stamped server-side.
--
-- Full Terms of Service / Privacy Policy pages and stricter age verification
-- ship in Phase 11; these timestamps are the MVP consent record.

alter table public.users
    add column terms_accepted_at       timestamptz,
    add column age_confirmed_at        timestamptz,
    add column onboarding_completed_at timestamptz;

-- Stamps the current user's onboarding consent in one shot.
--
-- security definer so the caller doesn't need an UPDATE policy on
-- public.users — which we deliberately avoid, since a self-update policy
-- would also have to prevent users from escalating their own `role`. This
-- function only ever touches the onboarding columns for the calling user,
-- so role escalation is impossible by construction.
--
-- The onboarding flow gates "Continue" on both the terms toggle and the 18+
-- toggle, so reaching completion implies both were accepted; we stamp all
-- three together. coalesce() preserves the first-acceptance time if the RPC
-- is somehow called more than once.
create or replace function public.complete_onboarding()
returns void
language sql
security definer
set search_path = public
as $$
    update public.users
    set terms_accepted_at       = coalesce(terms_accepted_at, now()),
        age_confirmed_at        = coalesce(age_confirmed_at, now()),
        onboarding_completed_at = now()
    where id = auth.uid();
$$;

-- Only signed-in users may complete their own onboarding.
revoke execute on function public.complete_onboarding() from public, anon;
grant execute on function public.complete_onboarding() to authenticated;
