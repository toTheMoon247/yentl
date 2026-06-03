-- Phase 4: allow a user to delete their own swipes.
--
-- Used by a DEBUG-only "Reset swipes" button in discovery (repopulates the feed
-- during testing). Benign in general — it's effectively "un-swipe" — but the UI
-- entry point is gated to debug builds so it never ships to real users.

create policy swipes_delete_own on public.swipes
    for delete to authenticated
    using (auth.uid() = from_user);
