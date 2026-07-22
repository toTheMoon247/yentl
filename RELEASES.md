# Releases

Milestone-based version history for Yentl. Each entry is a **significant, tested
checkpoint** — a stable, verified state of the project — not a per-commit log.
Every entry has a matching annotated Git tag, so any milestone is a clean
rollback point if later work breaks something.

## Conventions

- **Tags are annotated and semver, pre-1.0:** `v0.MINOR.0`. The minor number
  bumps once per milestone. `v1.0.0` is reserved for the first App Store launch
  (Phase 13).
- **Interim patch tags** (`v0.MINOR.PATCH`) may mark a verified mid-milestone
  checkpoint — e.g. one slice of a multi-slice phase, plus a substantial round of
  fixes — when it's a worthwhile rollback point. The next `.0` still marks the
  full milestone.
- **A milestone is only tagged when it is verified:** CI is green on the tagged
  commit *and* the milestone's behavior has been exercised (built/run, or
  validated end-to-end where it involves runtime auth/UI).
- **Major milestones only.** Examples: Google OAuth complete, Authentication
  complete, Onboarding complete, Profile Creation complete. Routine commits,
  refactors, and CI tweaks do not get entries.
- Entries are newest-first.

## Rolling back

To return to a known-good milestone:

```bash
git checkout v0.1.0          # inspect the milestone (detached HEAD)
# or, to branch from it and continue:
git switch -c recover-from-0.1.0 v0.1.0
```

`git tag` lists all milestones; `git show v0.1.0` shows the tag's notes and the
commit it points at.

---

## v0.9.0 — Phase 9: Payments (2026-07-22)

The per-confirmed-date fee, via Apple IAP through **RevenueCat**. Verified
end-to-end: two real (Test Store) purchases unlocked a chat in one continuous
run, and a forged purchase was rejected. CI green; 35 shared unit + 108 pgTAP.

- **Model:** each participant pays their own fee; once **both** have paid, the
  chat unlocks. RevenueCat validates the purchase with Apple; we keep our own
  per-match `payments` ledger (its entitlement model can't express a per-match
  consumable), and a RevenueCat webhook handles refunds.
- **`record-payment` Edge Function (deployed).** Identity from the verified JWT;
  participant + confirmed-match gated; then **independently re-verifies** the
  purchase against RevenueCat's REST API (secret key, server-side) before
  writing a paid row. Idempotent on the store transaction id. **Verified live:**
  a real purchase records; a **fake transaction is rejected 402** — you cannot
  fake your way past the paywall.
- **`revenuecat-webhook` (deployed).** Constant-time shared-secret auth (fails
  closed); flips rows to refunded on refund/cancellation, restores on reversal.
  Webhook registered in RevenueCat and verified live.
- **`payments` ledger + `is_match_paid(match)`** (both participants paid) — the
  chat-unlock predicate. Own-or-staff RLS; writes only via the functions.
- **Consumer app:** RevenueCat SDK (Test Store, so purchases work in the
  simulator with no App Store Connect), app-user-id = the Supabase user id, and
  a "pay to unlock chat" gate: pay → "waiting for them" → chat opens
  automatically when both have paid. Verified on-device flow in the simulator.

Migration: `20260722110000_payments`. Edge Functions: `record-payment`,
`revenuecat-webhook` (deployed; join `stream-token`, `stream-channel`, `notify`).
Secrets (`REVENUECAT_SECRET_KEY` / `PROJECT_ID` / `WEBHOOK_AUTH`) server-side only.

**Not included** (deferred, tracked): the **real App Store Connect IAP product**
+ ASC link (launch prep — dev uses RevenueCat's Test Store); the
one-pays-then-ghosts refund/timeout policy; anti-gaming (repeat confirm-then-ghost).
The **Apple IAP-eligibility of a real-world date fee is still unconfirmed** with
Apple — a reviewer ruling otherwise would reshape the purchase layer.

---

## v0.8.0 — Phase 8: Notifications (2026-07-22)

Push notifications, verified end-to-end on a **physical iPhone** — both push
systems delivering side by side. CI green; 92 pgTAP + 25 shared unit tests.
All secrets (OneSignal REST key, Stream secret, the APNs `.p8`) live server-side
or in the vendor dashboards, never in the app or repo.

- **Hybrid push, both proven on-device.** Match-lifecycle events (**created**,
  **confirmed**) go through **OneSignal**; **new chat messages** go through
  **Stream's native push**. The two share one APNs token without conflict —
  OneSignal's registration swizzle calls through to the app's own token
  callback, which forwards it to Stream, and OneSignal's extension passes
  Stream's notifications through untouched.
- **`notify` Edge Function (deployed).** Sends OneSignal lifecycle pushes to both
  participants, addressed by `external_id` (the Supabase user id set via
  `OneSignal.login`). Identity from the verified JWT; participant-or-staff gated;
  **state-gated** so firing on every accept only pushes when the match actually
  confirms; deterministic idempotency key.
- **Notification settings + preferences.** A `notification_preferences` table
  (own-row RLS) backs a settings screen with **Match** and **Message** toggles.
  Match opt-out is enforced server-side in `notify` (opted-out recipients are
  excluded); Message opt-out flips the Stream device registration at the source,
  so chat pushes genuinely stop. Absent row = opted in (no backfill).
- **Permission prompt moved into onboarding** (asked once, not on every home
  appearance).
- **Consumer-app device signing** configured (App Group + push entitlement + the
  Notification Service Extension), enabling on-device builds.

Migrations: `20260722100000_notification_preferences`. Edge Functions: `notify`
(deployed; joins `stream-token`, `stream-channel`).

**Not included** (deferred, tracked in `docs/implementation-plan.md`, none
blocking): the *match-expiring-soon* reminder (needs a scheduler — deferred by
choice), rejected/expired pushes (sensitive wording), push-tap deep-link routing
(the data payload is sent but not yet routed on tap), a dedicated in-app
notification center (the Matches/Chat tabs cover it for now), OneSignal Identity
Verification (anti-impersonation lock — needs a signed-token endpoint first), and
matchmaker-app pushes (a second OneSignal app).

---

## v0.7.0 — Phase 7: Chat (2026-07-22)

Phase 7 complete. Confirmed matches get a private, real-time chat, built on
Stream Chat with all secret-signing server-side. CI green; 79 pgTAP + 21 shared
unit tests.

- **Token issuance (`stream-token` Edge Function, deployed).** Issues Stream
  user tokens so the API secret never ships in the client. The Stream user id
  is derived solely from the caller's verified Supabase JWT — the request body
  is never read — so a caller cannot mint a token for anyone else. Verified live,
  including that a body-supplied id is ignored.
- **Chat UI.** Stream SwiftUI SDK (5.6.0) in the consumer app: inbox +
  conversation, reachable from a confirmed match. Real messages between two
  users verified on-device. Read receipts and typing indicators come native
  with the SDK.
- **Server-side channel creation (`stream-channel` Edge Function, deployed).**
  On a confirmed match, upserts both Stream users and creates the channel —
  something the client could not do reliably (a partner who never connected has
  no Stream user). Participant-only and confirmed-only, enforced from the JWT;
  idempotent. Verified against real Stream: non-participant → 403.
- **48h inactivity archive** as pure view-state, derived from last activity
  (never stored, no channel freeze): archived chats move to a collapsible
  section and a new message brings them back. The clock starts at channel
  creation, so a never-messaged match archives on the same rule.
- **Block & report.** Block ends the match (terminal `blocked` state, chat
  hidden both sides, messaging stops) and records a "do not re-pair" signal;
  report uses canned reasons + optional note. Participant guard verified live.

Migrations: `20260722090000_blocks_and_reports`. Edge Functions: `stream-token`,
`stream-channel` (both deployed). Stream API secret held as a Supabase function
secret; API key is public and ships in the app.

**Not included:** the matchmaker moderation queue, bans, and global re-match
prevention are Phase 11 (built on the blocks/reports data). Token refresh at the
1h expiry and physical-device behaviour were not exercised. Block/report is
compile- and logic-verified (pgTAP + a live participant-guard check) but was not
driven through the UI on-device this session.

---

## v0.6.0 — Phase 6: Match Creation & Confirmation (2026-07-22)

Phase 6 complete. The plan's exit criteria — the "ignored = rejected" rule
holding in three scenarios — is met, each one exercised in-app against the live
database rather than only in tests. CI green; 45 pgTAP + 8 shared unit tests.

- **Expiry proven end-to-end, logic and scheduler separately.** A match left
  unanswered flips to `expired` and both users return to the queue by their own
  response. Verified twice: once by invoking `expire_stale_matches()` by hand
  (the *logic*), and once by creating a match, accepting on one side, and then
  writing nothing at all — the pg_cron sweep expired it unaided (the
  *scheduler*), reaching both the database and the app UI.
- **Explicit rejection** (never previously tested) in both orderings: accept →
  reject, and reject-first with the other side silent. Both resolved in 26–42s,
  well inside the window, confirming a rejection ends a match immediately rather
  than waiting out the timer.
- **Match history:** `matches.resolved_at` (when a match left `pending` — the
  schema previously recorded creation and expiry but never the actual outcome
  time), plus staff-only `match_history_for_user` / `recent_matches` RPCs. New
  matchmaker **Matches** tab (recent-matches dashboard) and per-user history,
  reachable from a dashboard row or the Decision Panel. Pending rows show a live
  countdown.
- **Outcome wording:** a match that fails now reads *"This match wasn't accepted
  by both people"* — identical whether the user declined, was declined, or
  nobody replied. Deliberate: clear about the outcome without telling someone
  they were personally turned down.
- **CI repaired after five weeks red.** No migration granted table privileges;
  the live project worked only because Supabase's hosted platform adds them at
  table creation. A CLI release between 2026-06-11 and 2026-06-18 stopped the
  local stack doing so, turning CI red on a docs-only commit. Grants are now
  explicit — meaning the migrations can rebuild a working database from scratch,
  which they previously could not. CLI pinned so a release cannot break CI
  again, and telemetry disabled (its shutdown hang was failing green runs).
- **Dev/test tooling:** DEBUG email/password sign-in for the OAuth-only
  matchmaker app and a signed-out test-login shortcut for the consumer app —
  between them, the whole match lifecycle is now drivable unattended. Reusable
  `MatchExpiry` / `MatchReject` / `MatchHistory` UI drivers.

Migrations: `20260721160000_match_history`,
`20260721170000_explicit_table_grants`.

**Not included:** the consumer app has no match-history screen — the
implementation plan defines none, so users cannot see their own past matches.
Match creation is a Postgres RPC, not the edge function the plan's backend
checklist names; behaviour is equivalent.

---

## v0.5.1 — Phase 6 Slice 1: Match Creation & Confirmation (interim) (2026-06-08)

Interim checkpoint: the first slice of Phase 6 plus a round of real fixes shaken
out by end-to-end testing. CI green; both sides of the match flow exercised
in-app. (Phase 6 isn't done — see "Not included" below.)

- **Match creation & confirmation (Slice 1):** the matchmaker **Match** button
  creates a match between the pinned user and a mutual candidate; the consumer
  **Matches** tab shows the pending match (the other person's profile + a 24h
  countdown) with **Accept / Reject**; both accept → confirmed, either rejects →
  not a match. `matches` table + `match_state` enum; participant/staff RLS;
  `create_match` / `my_matches` / `respond_to_match` security-definer RPCs.
- **Matchmaker UX:** jump-to-pin (tap a Queue row → that user's Decision Panel
  pinned, not a read-only profile); a failed match (e.g. user already has a
  pending match) is a non-fatal alert, so the panel stays put.
- **Real bugs surfaced by testing, now fixed:**
  - **Consumer photo RLS:** live profiles' photos were unreadable by normal
    consumers (the liveness check sub-queried owner/staff-only `profiles`), so
    discovery showed placeholders for everyone but staff — fixed with a
    `security definer is_profile_live()`; hidden columns stay locked.
  - **Queue alternation:** the M/F queue only ever pinned women; switched to
    FIFO by `enqueued_at` with a re-interleave so it alternates.
- **Dev/test tooling:** DEBUG test-login picker (sign in as any seed; one-tap
  **back to my real account** via session restore); real gendered seed names
  (Kanyin matched to her photo); seed-photo upload made clean (storage purge on
  re-run + CSV last-row fix); `respond_as_seed` / `reset_queue` / `reset_matches`
  helpers.

Migrations: `20260607072236_matches`, `20260607123917_queue_fifo_alternation`,
`20260607194500_live_photo_rls_fix`.

Not included (Phase 6 remaining): 24h auto-expiry / "ignored = rejected"
(Slice 2); match history + matchmaker recent-matches dashboard (Slice 3); a more
prominent countdown clock on both sides (tracked).

## v0.5.0 — Matchmaker Queue & Decision Panel (2026-06-06)

Phase 5 complete: a matchmaker pulls up the front-of-queue user and reviews
their mutual-like candidates in the Decision Panel. Validated against seeded
data; CI green. (Creating the match is Phase 6.)

- **Queue:** `matchmaking_queue` (M/F alternating), enqueued on profile go-live
  (trigger + backfill). Staff-only security-definer RPCs: `next_queued_user`,
  `queued_profiles` (Queue tab), `requeue_user` ("Next profile" — non-destructive,
  sends the user to the back), `matchmaker_candidates`, `matchmaker_like_stats`.
- **Candidates = mutual likes** (liked both ways), shown in a swipeable card
  carousel; tap a card for the full profile (with hidden fields).
- **Empty state is a decision:** a received-vs-given diagnostic steers Boost
  (Phase 10) vs Next.
- **Matchmaker app:** Review + Queue tabs; card-based panel with a pinned-user
  card, Match/Boost buttons (stubbed for Phases 6/10), and an account menu.
  Photos use the shared in-memory image cache (instant).

Migrations: `20260605203625_matchmaking_queue`, `20260606071144_queue_list_and_requeue`.

Decisions: candidates are mutual-only (matchmaker curates among mutual interest);
internal notes and the compatibility indicator cut; **attractiveness rating +
percentiles deferred to post-MVP** (subjective, calibration-heavy — closes Phase 5
at one slice). Dev: `seed_mutual_likes.sql` creates varied mutual counts.

Not included: match creation + 24h confirmation (Phase 6); Boost mechanic
(Phase 10); attractiveness rating / percentiles (post-MVP).

## v0.4.0 — Discovery & Likes (2026-06-04)

Phase 4 complete: users swipe through other live profiles and the system records
likes/passes (no matches yet — those come from the matchmaker). Validated
end-to-end against seeded profiles; CI green.

- **Discovery feed:** `discovery_feed` security-definer RPC returns only public
  columns for live, opposite-gender, not-yet-swiped candidates — so the hidden
  height/income never leak to other consumers. `swipes` table + `swipe_action`
  enum with own-RW / staff-read RLS (no consumer-facing "likes you" — that data
  is the matchmaker's, in Phase 5).
- **Review state (mocked Phase 3):** `profile_review_state` column on `profiles`,
  set to `live` on completion for MVP; discovery filters on it. The real
  approval pipeline stays Phase 12.
- **Yentl UI:** a new tab bar (Discover / Profile); a draggable `SwipeCard`
  (drag or buttons to like/pass, tap for full detail), empty/error states, and a
  DEBUG-only "Reset swipes" button for testing.
- **Performance:** next-card photo prefetch + an in-memory decoded-image cache,
  so swiping feels instant after the first card.

Migrations: `20260603171739_discovery_and_swipes`, `20260603193210_swipes_delete_own`.

Dev tooling: `supabase/dev/seed_profiles.sql` (40 seeded profiles) and
`upload_seed_photos.sh` (gender-matched photo upload). Also: repo made public
(free CI) and the `profile-photos` storage read RLS extended so live profiles'
photos are visible in discovery.

Not included (tracked, deferred): photo URLs in the feed RPC; image variants
(thumb/medium/full); CDN; the `profile_approval_enabled` flag (lands in Phase 12
where it's first used).

## v0.3.0 — Profile Creation (2026-06-03)

Phase 2 complete: a user builds a full profile in Yentl and a matchmaker opens
it (public + hidden fields) in Yentl Matchmaker. Validated end-to-end; CI green.
Built in five vertical slices, each its own CI-green commit:

- **Slice 1 — Basics:** `profiles` table + `gender` enum + owner/staff RLS;
  `ProfileService` (`saveBasics`/`isProfileComplete`); basics wizard step; an
  **account-stage router** (onboarding → profile → ready) folding in the
  Phase-1 account-state model.
- **Slice 2 — Photos:** `profile_photos` table + a **private storage bucket**
  with per-user-folder RLS; upload/reorder/delete/signed-URL ops; client-side
  downscale; PhotosPicker UI. (Fixed an RLS bug: Swift's uppercase UUID vs
  Postgres lowercase `auth.uid()`.)
- **Slice 3 — Details:** bio / height / income / `interests[]` columns +
  `profile_prompts` table; **preset** prompt & interest lists; details step
  (optional) + private step (**height/income required**).
- **Slice 4 — Preview & viewer:** reusable `PublicProfileCard` + `ProfileScreen`
  loader (shared); wizard **preview** step; consumer **home shows your own
  profile**; matchmaker **profile browser → viewer with hidden height/income**.
- **Slice 5 — Edit:** reusable `PhotoManager`; `EditProfileView` (single
  prefilled form); **Edit** button on home with refresh-on-save.

Migrations: `20260602200247_profiles_table`, `20260603025651_profile_photos`,
`20260603031656_profile_details`.

Decisions locked: height/income **required**; prompts/interests from fixed
**preset lists**; hidden fields stored on `profiles` (protecting them from other
consumers is the Phase 4 discovery projection's job).

Not included (tracked for later): image variant generation (thumb/medium/full —
deferred within Phase 2; one downscaled JPEG per photo for now); profile
approval (mocked in Phase 3, real in Phase 12).

## v0.2.0 — Onboarding (2026-06-01)

Post-sign-in onboarding for the Yentl consumer app, validated end-to-end in the
simulator; CI green on all jobs.

- After first Google sign-in, signed-in users pass through a one-time onboarding
  gate before the home screen: **Welcome → privacy note → terms/consent + 18+
  confirmation** (both toggles required to continue).
- Consent is recorded **server-side, account-scoped** (not device-local):
  migration `20260601202049_onboarding_fields.sql` adds `terms_accepted_at`,
  `age_confirmed_at`, and `onboarding_completed_at` to `public.users`, plus a
  `security definer` `complete_onboarding()` RPC that stamps them for
  `auth.uid()` only (no self-UPDATE RLS policy, so role escalation stays
  impossible by construction).
- `AuthService.isOnboardingComplete()` / `completeOnboarding()`; Yentl
  `ContentView` routes through `OnboardingFlow` until completion, mirroring the
  Matchmaker role-gate pattern.
- Verified persistence: relaunching after completion routes straight to home.

Not included (tracked for later): full Terms of Service / Privacy Policy pages
and stricter age verification (Phase 11); onboarding gate for the Matchmaker app
(staff-only, not needed yet).

## v0.1.0 — Authentication (2026-05-31)

First known-good checkpoint. The authentication system is complete and verified
on both apps; CI is green on all jobs.

- Google Sign-In + Supabase Auth handshake, validated end-to-end in the
  simulator (Google → callback → `auth.users` → trigger → `public.users`).
- Backend: `public.users` table, `user_role` enum (`user`/`matchmaker`/`admin`),
  auto-creation trigger, and RLS policies (migration
  `20260530202003_users_table_and_rls.sql`).
- Matchmaker role gate validated: `user` → Access Pending; promotion to
  `matchmaker`/`admin` → `MatchmakerHomeView`.
- Session persistence (Keychain, auto-refresh) made explicit; shared
  `SignOutButton` wired into both apps; logout reliable offline.
- CI green across shared package, both iOS app builds, and SwiftLint
  (iOS builds run via shared schemes).

Not included (tracked for later milestones): onboarding screens
(welcome/privacy/terms), the full account-state model, and real Apple Sign-In
(stubbed until Phase 8).
