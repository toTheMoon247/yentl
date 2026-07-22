-- Phase 8 (Slice 3): per-user notification preferences.
--
-- Two toggles, surfaced on the consumer app's Notification Settings screen:
--   - match_pushes:   the OneSignal lifecycle pushes ("You have a new match!",
--                     "It's a match!"). Read server-side by the `notify` Edge
--                     Function (service-role) before it targets a recipient.
--   - message_pushes: Stream chat-message pushes. Enforced client-side — the
--                     app registers/removes its Stream push device to match
--                     this value (ChatService), because those pushes are sent
--                     by Stream, not by anything that can read this table.
--
-- Opt-out model: NO ROW MEANS BOTH ON. Every existing user is opted in
-- without a backfill, and a row appears only once someone touches a toggle.
-- Anything reading this table must treat an absent row as true/true.
--
-- Writes are plain client-side upserts under RLS (no RPC): unlike matches or
-- blocks, a preference row has no side effects to keep in sync, so the
-- security-definer convention would be ceremony without benefit here.

create table public.notification_preferences (
    user_id        uuid primary key references public.users(id) on delete cascade,
    match_pushes   boolean not null default true,
    message_pushes boolean not null default true,
    updated_at     timestamptz not null default now()
);

-- Keep updated_at fresh (reuses the helper from the users migration).
create trigger notification_preferences_updated_at
    before update on public.notification_preferences
    for each row execute function public.handle_updated_at();

alter table public.notification_preferences enable row level security;

-- Own row only, for every verb the client needs. No staff read: matchmakers
-- have no business knowing who muted their pushes. No delete policy: the app
-- only ever flips booleans (deleting a row would just mean "both on" anyway).
create policy notification_prefs_select_own on public.notification_preferences
    for select to authenticated
    using (auth.uid() = user_id);
create policy notification_prefs_insert_own on public.notification_preferences
    for insert to authenticated
    with check (auth.uid() = user_id);
create policy notification_prefs_update_own on public.notification_preferences
    for update to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- Explicit table grants, per 20260721170000: RLS is the gate; grants are
-- mirrored broad so local, CI and production behave identically. The `notify`
-- function reads via service_role, which bypasses RLS.
grant select, insert, update, delete on table
    public.notification_preferences
to anon, authenticated, service_role;
