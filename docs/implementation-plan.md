# Implementation Plan

This plan breaks Yentl's MVP into small, sequenced tasks grouped by phase. Each phase has a clear exit criterion. Phases are mostly sequential — later phases assume earlier ones are done.

## Quick Map

| Phase | What ships |
| ----- | ---------- |
| 0     | Foundations — two iOS skeletons + Supabase + CI |
| 1     | Auth — Apple/Google for users, allow-listed login for matchmakers |
| 2     | Profile creation + storage (photos, bio, hidden fields) |
| 3     | Profile approval (mocked) — *folded into Phase 4* |
| 4     | Discovery + likes in Yentl (+ mocked review state) |
| 5     | **Decision Panel** — the core matchmaker UX |
| 6     | Match creation + 24h confirmation + queue updates |
| 7     | Chat (Stream) |
| 8     | Push notifications (OneSignal) |
| 9     | Apple IAP per-confirmed-date fee |
| 10    | Boost mechanic |
| 11    | Safety, moderation, observability |
| 12    | Profile approval pipeline (full) — launch gate |
| 13    | Beta + launch in one city |

## Conventions

- "Yentl" = the iOS app users see (the public consumer app).
- "Yentl Matchmaker" = the iOS app matchmakers use (internal only).
- "Backend" = Supabase (Postgres + Auth + Storage + Edge Functions).
- Open decisions are tagged **(OPEN)** and need answers before the task can ship.

---

## Phase 0 — Foundations

Goal: a clean, deployable skeleton for both iOS apps and the backend, with CI in place.

- [ ] Create Supabase project (dev) and capture connection details *(deferred to Phase 1)*
- [ ] Set up Apple developer assets (App IDs, certificates, provisioning) for both apps *(deferred until TestFlight)*
- [x] Initialize the Yentl Xcode project (SwiftUI, iOS 17+ target)
- [x] Initialize the Yentl Matchmaker Xcode project (SwiftUI, iOS 17+ target)
- [x] Create a shared Swift package for models, API client, and shared utilities (`shared/`, library `YentlShared`)
- [x] Configure SwiftLint and a basic CI pipeline (build + lint on PR) for both apps (`.swiftlint.yml`, `.github/workflows/ci.yml`; iOS jobs use `xcodebuild -target` to avoid shared-scheme dependency)
- [x] Set up environment configuration (dev / staging / prod) for both apps and Supabase (`AppEnvironment` enum in `YentlShared` reads `YENTL_ENV` from Info.plist; URLs/keys wired up alongside Supabase in Phase 1)
- [x] Create a design tokens file (colors, typography, spacing) shared between both apps (`DesignTokens.swift` in `YentlShared` — placeholders pending real design)

Exit: both apps build, run on simulator, hit a "hello" endpoint on Supabase, CI is green. *Currently: both apps build and run on the simulator locally; CI is wired but not yet observed green on a real PR; the Supabase "hello" check is moved to Phase 1 along with the Supabase project itself.*

---

## Phase 1 — Identity & Auth

Goal: users and matchmakers can sign up, log in, and stay logged in across launches.

### Yentl
- [ ] Onboarding screens — welcome, privacy, terms acceptance
- [ ] Apple Sign-In flow + Supabase Auth handshake
- [x] Google Sign-In flow + Supabase Auth handshake — validated end-to-end in the simulator
- [x] Persistent session handling and logout — session persists in the Keychain across launches (auto-refresh on); shared `SignOutButton` wired into the signed-in home
- [ ] Account state model (logged out / no profile / profile pending / profile live / rejected)

### Yentl Matchmaker
- [x] Google Sign-In + Supabase Auth handshake — validated end-to-end; Apple Sign-In remains a stub until Phase 8 (Apple Developer enrollment)
- [x] Role-based access check on app launch — validated: `user` role sees Access Pending; promoting to `matchmaker`/`admin` routes to `MatchmakerHomeView`
- [x] Logout — shared `SignOutButton` on both the staff home and Access Pending screens

### Backend
- [x] `users` table with role column (`user` / `matchmaker` / `admin`) — migration `20260530202003_users_table_and_rls.sql`
- [x] Row Level Security policies on `users` — same migration
- [x] Matchmaker promotion flow — admin promotes a user's role from `user` to `matchmaker` in `public.users` (via Supabase Studio SQL for MVP; admin UI built later) — validated

Exit: a fresh install of either app can sign up via Apple or Google; the Matchmaker app then gates access on the `role` column — non-matchmakers see an "access pending" state until promoted by an admin.

Auth method note: Apple + Google only. Email/password is intentionally not supported. App Store Review Guideline 4.8 requires Sign in with Apple when offering Google sign-in, so both ship together; Apple sign-in is blocked on getting an Apple Developer account.

---

## Phase 2 — Profile Creation & Storage

Goal: users can complete a profile with photos, bio, prompts, and the hidden matchmaker fields.

### Yentl
- [x] Profile creation wizard — basics (name, DOB, gender — male/female only at MVP, location)
- [x] Photo upload UI (multi-photo, reorder, delete) — `PhotoManager`, PhotosPicker + signed URLs
- [x] Bio and prompts entry — prompts chosen from a preset list
- [x] Interests selection — preset list, multi-select
- [x] Height and income inputs — **resolved: required** to finish (hidden matchmaker fields)
- [x] Profile preview screen (what others will see) — final wizard step
- [x] Profile edit screen post-approval — `EditProfileView` (single form, prefilled)

### Backend
- [x] `profiles` table schema (public fields + hidden fields)
- [x] `profile_photos` table with order index
- [x] Supabase Storage bucket for profile photos, with RLS (per-user folder)
- [ ] Image resize / variant generation on upload (thumb, medium, full) — *deferred within Phase 2; currently a single client-side downscaled JPEG per photo*
- [x] Photo deletion + storage cleanup — `deletePhoto` removes the file + row

### Yentl Matchmaker
- [x] Profile viewer (mirrors Yentl's profile view, plus hidden matchmaker fields) — browsable list → `ProfileScreen` with hidden fields

Exit: a user can build a full profile in Yentl; a matchmaker can open that profile in Yentl Matchmaker and see both public + hidden fields.

---

## Phase 3 — Profile Approval (Mocked for MVP) — **folded into Phase 4**

Decision (2026-06-03): Phase 3 is no longer a standalone phase. It was only ever a *mock* (profiles go live immediately; the real approval pipeline is Phase 12), and its sole substantive work is two schema placeholders. Those have moved into Phase 4, where `profile_review_state` is first actually consumed (discovery must show only `live` profiles). Doing it there means we write the "live only" filter once, correctly, instead of retrofitting every profile-touching query later.

What moved to Phase 4's backend:
- `profile_review_state` enum + column (`draft / pending_ai / pending_review / live / rejected`), defaulting to `live` on completion for MVP.
- Feature flag `profile_approval_enabled` (default `false`; flipped on in Phase 12).

Unchanged: profiles go live immediately (no "under review" UI during MVP); no matchmaker approval queue (Phase 12); matchmaker-assigned attractiveness rating lives in Phase 5. The full approval pipeline (AI screening, approval queue, rejected/resubmit UX, retroactive review) remains **Phase 12**.

---

## Phase 4 — Discovery & Likes (Yentl side)

Goal: users can swipe on each other and accumulate "likes received". No matches yet — that comes from the matchmaker.

### Yentl
- [x] Discovery stack screen (card swiper, photos, basic info) — draggable `SwipeCard` (drag/buttons), photo prefetch + in-memory image cache
- [x] Profile detail view from the stack — tap a card → full `PublicProfileCard` sheet with like/pass
- [x] Like / pass actions — recorded to `swipes`; DEBUG-only "Reset swipes" for testing
- ~~"Likes you" inbox~~ — **cut (2026-06-03).** Yentl has no consumer-facing "who likes you" feed; it runs against the matchmaker-curated premise. Received-like data still feeds the matchmaker's candidate ordering (Phase 5). May revisit later (e.g. as a post-MVP/premium idea).
- [x] Empty states (no one new, "you've seen everyone") + error/retry

### Backend
- [x] `profile_review_state` enum + column on `profiles` (`draft / pending_ai / pending_review / live / rejected`), defaulting to `live` on completion for MVP *(folded in from Phase 3)*
- [ ] Feature flag `profile_approval_enabled` — **deferred to Phase 12.** Nothing reads it until the real approval pipeline exists, so adding it now would be dead config; it lands with Phase 12 where it's first used.
- [x] `swipes` table (from_user, to_user, action, created_at) — `swipe_action` enum, own-RW/staff-read RLS, indexes
- [x] Discovery query: candidates the user has not yet swiped on, opposite gender, `review_state = 'live'` — the `discovery_feed` RPC (recent-first for MVP; "likes-you-first" is the matchmaker's Decision Panel in Phase 5)
- [x] Public-profile projection for discovery — `discovery_feed` is a security-definer projection of public columns only; height/income never leave the owner/staff scope *(hidden-field protection from Phase 2)*
- [x] Index strategy for discovery query — `swipes` indexed on from/to; adequate for MVP (revisit profile-side indexes at scale)

Exit: two test users can each swipe on each other and the system records likes — but no match is created until a matchmaker creates one. (No consumer-facing "likes you" view — that data is the matchmaker's, surfaced in Phase 5.)

Deferred Phase 4 perf (revisit later): fold photo URLs into the `discovery_feed` RPC to skip the per-card `listPhotos` + sign round-trips; image variant generation (thumb/medium/full, also deferred from Phase 2); CDN. The in-memory image cache + next-card prefetch already make swiping feel instant after the first card.

---

## Phase 5 — Matchmaker Queue & Decision Panel

Goal: the core differentiating UX. Matchmakers pull up the front-of-queue user and review their mutual-like candidates in the Decision Panel. (Creating the match is Phase 6.)

Decisions (2026-06-05):
- **Candidates = mutual likes.** For a pinned user, candidates are people who liked the pinned user *and* whom the pinned user also liked (a like in both directions). This replaces the old "liked-you first, then fallback" ordering — there is no fallback pool. Ordered most-recent-mutual first.
- **No internal notes.** Cut deliberately — free-text notes on people risk turning the tool into a CRM and storing subjective commentary.
- **Empty candidate state is a decision, not a dead end:** show a quick diagnostic (likes *received* vs *given*) and steer the matchmaker — **Boost** if the user isn't *receiving* likes (a visibility problem), **Skip** if they aren't *giving* likes (an engagement problem boosting can't fix). The Boost action is surfaced here but **wired up in Phase 10** (its mechanic is that phase).
- **No compatibility indicator** — mutual-like already is the strongest fit signal, so a compatibility bar adds little. (Revisit later if wanted.)
- **Attractiveness rating + percentiles deferred to post-MVP (2026-06-06).** The matchmaker-assigned attractiveness rating is subjective, needs cross-matchmaker calibration to mean anything, and a stored "hotness score" is a liability during early testing — so it's a post-MVP nice-to-have. The height/income/activity/attractiveness **percentiles** go with it: they're decision-*aids* (the panel already shows the matchmaker raw height/income + the full profile), "activity" isn't even defined yet, and percentiles need population data + tuning. With both deferred, **Phase 5 is complete at Slice 1.**

### Backend
- [x] `matchmaking_queue` table (M / F alternation), enqueue on profile go-live (trigger + backfill)
- [x] Queue advancement / front-of-queue + non-destructive "Next profile" (re-queue) — `next_queued_user`, `requeue_user`, `queued_profiles` RPCs
- [x] Mutual-likes candidate query (both directions) — `matchmaker_candidates` security-definer RPC, staff-only
- [x] Like-stats (received vs given) for the empty-state diagnostic — `matchmaker_like_stats`
- [ ] ~~Attractiveness rating + height/income/activity/attractiveness percentiles~~ — **deferred to post-MVP** (see decision above)
- ~~Percentile calculation jobs~~ — deferred with percentiles
- ~~Internal notes table~~ — **cut**

### Yentl Matchmaker
- [x] Decision Panel — pinned user card (photo + hidden height/income)
- [x] Decision Panel — candidate viewer (mutual likes, swipeable carousel)
- [x] Profile inspection tap-through (full profile sheet, with hidden fields)
- [x] "Next profile" action (re-queue without matching) + Queue tab (up-next order)
- [x] Empty-state diagnostic (received vs given likes) → Boost (Phase 10) / Next
- [ ] **Queue → jump-to-pin** (follow-up, post-v0.5.0): tapping a user in the Queue tab pins them in the Decision Panel (review/match them out of order) instead of just opening the read-only profile
- [ ] ~~First-encounter attractiveness rating prompt~~ — **deferred to post-MVP**
- ~~Candidate ordering fallback~~ — moot (candidates are exactly the mutual-like set)
- ~~Compatibility indicator~~ — **cut**
- ~~Internal notes editor~~ — **cut**

Exit: a matchmaker can pull up a queued user and review their mutual-like candidates in the Decision Panel; the empty state steers toward Boost vs Next. **Met.** (Match / Boost buttons are shown but wired in Phases 6 / 10.)

---

## Phase 6 — Match Creation & Confirmation

Goal: a matchmaker creates a match, both users see it, the 24-hour clock starts, the queue updates correctly.

### Backend
- [ ] `matches` table (user_a, user_b, created_by_matchmaker, state, created_at, expires_at)
- [ ] Match creation edge function (state: `pending`)
- [ ] 24-hour expiry job (cron or scheduled function)
- [ ] State transitions: `pending` → `both_confirmed` / `rejected` / `expired`
- [ ] Queue updates on outcome (drop rejecting/ignoring user, return other to front)
- [ ] Match history per user

### Yentl
- [ ] Incoming match notification UI
- [ ] Match detail screen (other user's full profile + accept / reject buttons + countdown)
- [ ] Accept / reject actions
- [ ] Outcome screens (confirmed, expired, not accepted by both). Decided
      2026-07-21: the rejected state deliberately does **not** reveal who
      declined — it reads "This match wasn't accepted by both people",
      identically whether the user rejected, was rejected, or nobody replied.
      Clear about the outcome without telling someone they were turned down.

### Yentl Matchmaker
- [ ] Match creation confirm-step from Decision Panel
- [ ] Match history view per user
- [ ] Recent matches dashboard

Exit: matchmaker creates a match; ignored = rejected logic plays out correctly in three scenarios (both accept, one rejects, one ignores).

---

## Phase 7 — Chat

Goal: confirmed matches get a private chat channel.

- [ ] Stream Chat integration (auth tokens issued by a Supabase edge function)
- [ ] Channel creation on match confirmation
- [ ] In-app chat UI (Yentl)
- [ ] Chat list / inbox screen
- [ ] Read receipts and typing indicators (Stream native)
- [ ] Block / report in chat — **decided 2026-07-22**:
  - **Block ends the match.** Blocking sets the match to a terminal `blocked`
    state, hides the chat for both people, and stops all messaging. Because
    Yentl is matchmaker-mediated, a block is a strong "do not pair us again"
    signal and records a flag matchmakers will see (the moderation *queue*
    itself is Phase 11).
  - **Report uses canned reasons + an optional note** (harassment,
    inappropriate photos, spam/scam, off-platform contact, other).
  - Scope split: **Phase 7 builds the data model (`blocks`, `reports`) and the
    in-chat block/report actions**; the matchmaker moderation queue, bans, and
    the profile-level report flow are **Phase 11**, built on this same data.
  - Global re-match prevention (blocking across all future discovery/queue) is
    deferred to Phase 11 enforcement; Phase 7 ends only the current match.
- [ ] Chat lifecycle — **decided 2026-07-22**, closing the last open question
      in this phase:
  - A chat **stays open after a date happens**. A confirmed date does not close
    the conversation; the product does not assume one date is the end.
  - A chat **archives after 48 hours of inactivity** — no message from either
    participant.
  - **Archived means hidden, not closed.** The chat moves out of the main inbox
    into an Archived section; either person can still open it, read the full
    history, and send a message, which returns it to the active inbox.
    Archiving is an inbox filter, not a state change on the relationship —
    chosen so a slow replier is not punished permanently, and so nothing is
    ever lost.
  - **The 48h clock starts at channel creation**, so a confirmed match neither
    person ever writes in archives on the same rule. One timer, one definition:
    *48h since the last activity, where channel creation counts as activity.*
  - Implementation note: because archived is a view state rather than a
    permission change, this needs no Stream-side channel freezing — it can be
    derived from `last_message_at` (falling back to channel creation) rather
    than stored, which avoids a scheduled job that could drift out of sync.
    Block/report remains a separate, harder boundary.

Exit: two test users who both confirm a match can chat in real time.

---

## Phase 8 — Notifications

> ✅ **Resolved 2026-07-22: the Apple Developer Program membership is active.**
> This was the long-lead blocker on Phases 8–9. It unlocks the APNs key needed
> here, plus (a) replacing the Apple Sign-In stub from Phase 1 with the real
> flow, and (b) StoreKit / App Store Connect work for Phase 9. The remaining
> external dependency for Phase 7 is Stream Chat credentials.

Goal: users and matchmakers get the right pushes at the right times.

> **Push split — decided 2026-07-22 (hybrid):** new-**message** pushes go
> through **Stream's native chat push**, not OneSignal. Stream already tracks
> unread counts and online state, so it produces correct message notifications
> and badging for free; relaying chat events to OneSignal ourselves would mean
> reimplementing that. **OneSignal carries only the match-lifecycle events**
> (created, confirmed, expiring-soon). Consequence: the **same APNs `.p8` key is
> uploaded to two places** — OneSignal *and* the Stream dashboard. Yentl is two
> apps (`com.yentl.app`, `com.yentl.matchmaker`) → **two OneSignal apps**, two
> App IDs; the matchmaker app has no chat, so only the consumer app needs Stream
> push.

- [x] APNs `.p8` auth key uploaded to OneSignal and Stream (same key) — **consumer app only**; the matchmaker OneSignal app is deferred (its pushes aren't MVP-critical)
- [x] OneSignal SDK in the consumer app (match-lifecycle events)
- [x] Stream native push wired for the consumer app (new-message)
- [x] Device registration on login, deregistration on logout
- [x] Push permission prompt in onboarding
- [x] Notification triggers — **match created + confirmed** via OneSignal; **new message** via Stream. *Verified on a physical device 2026-07-22.*
- [x] Per-category notification settings screen (match / message toggles)
- [x] `aps-environment` entitlement + push-enabled provisioning (consumer app + its extension)

**Deferred past `v0.8.0`** (tracked, none blocking):
- [ ] **match expiring-soon reminder** — needs a scheduler (pg_cron + pg_net, or external cron); decided 2026-07-22 to defer past v0.8.0
- [ ] **match rejected / expired** pushes — sensitive (must stay non-attributing); design left open
- [ ] **push-tap deep-link routing** — the `data` payload is sent (route/match_id); the app doesn't yet route on tap
- [ ] **in-app notification center** — largely covered today by the Matches and Chat tabs (which already surface match activity + unread messages); a dedicated screen is deferred unless it proves needed
- [ ] **OneSignal Identity Verification** — the anti-impersonation lock; needs a signed identity-token endpoint before the dashboard toggle is enabled
- [ ] **matchmaker-app pushes** — second OneSignal app; deferred with the matchmaker notification needs

Exit (core, met at `v0.8.0`): match created/confirmed fire a push, and a new
chat message pushes via Stream — **verified on a physical device** 2026-07-22
(both push systems coexisting). The deferred items above are additive.

---

## Phase 9 — Payments (Apple IAP)

Goal: per-confirmed-date fee charged via Apple IAP at the moment both users confirm.

**Decisions (2026-07-22):**
- [x] **Build as Apple IAP.** Working assumption that Apple treats the
      per-confirmed-date fee as IAP-required. Not confirmed in writing with
      Apple; if a reviewer later rules it a real-world service (Stripe-eligible),
      the purchase layer would need rework. Doesn't block building.
- [x] **Via RevenueCat**, not raw StoreKit — chosen 2026-07-22. RevenueCat owns
      the security-critical receipt validation and refund/dispute webhooks (the
      riskiest parts to build ourselves). Its **entitlement** model doesn't fit a
      per-match consumable, so **we keep our own `payments` ledger** mapping
      RevenueCat transactions → matches; RevenueCat is a validation + webhook
      layer. See `docs/tech-stack.md`.
- [x] **Each participant pays their OWN fee** (symmetric, independent).
- [x] **Paying unlocks the chat**: both accept → confirmed → each pays → once
      BOTH have paid, the conversation (Phase 7) unlocks.

**Architecture:** RevenueCat SDK in the consumer app, its app-user-id set to the
Supabase user id (same pattern as OneSignal/Stream). On purchase RevenueCat
validates with Apple; the client then tells our `record-payment` Edge Function
"paid for match X", which **re-verifies against RevenueCat's REST API** (never
trusts the client) and writes a `payments` row tied to the match + user. A
RevenueCat **webhook** Edge Function handles refunds/chargebacks → updates the
ledger. `is_match_paid(match)` = both participants have a paid row; the chat gate
reads it.

**Build checklist:**
- [ ] RevenueCat project/app for `com.yentl.app`; consumable product/offering
      configured; linked to App Store Connect (IAP product + ASC API key)
- [ ] RevenueCat SDK in the consumer app; app-user-id = Supabase user id
- [ ] `payments` table + `is_match_paid()` helper; payment history per user
- [ ] Purchase flow (buy the date fee via RevenueCat)
- [ ] `record-payment` Edge Function (re-verifies via RevenueCat REST API)
- [ ] RevenueCat webhook Edge Function → refunds/chargebacks update the ledger
- [ ] "Pay to unlock chat" gate on the confirmed match (chat opens when both paid)
- [ ] **Deferred:** the one-pays-other-ghosts refund/timeout policy, and
      anti-gaming (repeat confirm-then-ghost) — data model tracks per-user
      payment status so both are handleable later

**RevenueCat API notes (verified against the current docs 2026-07-22, while
building the backend slice):**
- Server-side verification uses REST API **v2**:
  `GET https://api.revenuecat.com/v2/projects/{project_id}/customers/{app_user_id}/purchases`
  with `Authorization: Bearer <secret key>` (v2 requires the Bearer prefix,
  unlike v1). Each purchase carries `store_purchase_identifier` (the App Store
  transaction id), a `status` that reads `refunded` when revoked, and
  RevenueCat's *internal* `product_id`. Function secrets/env therefore:
  `REVENUECAT_SECRET_KEY`, `REVENUECAT_PROJECT_ID` (v2 paths are
  project-scoped), optional `REVENUECAT_PRODUCT_ID` (pin the date-fee
  product), `REVENUECAT_API_BASE_URL` (local-mock override).
- Webhooks POST `{ "api_version": "1.0", "event": { type, app_user_id,
  transaction_id, ... } }` where `transaction_id` is the store transaction id
  — the same value the ledger dedups on. Auth is a dashboard-configured
  Authorization header sent verbatim with every delivery
  (`REVENUECAT_WEBHOOK_AUTH`); optional HMAC signing
  (`X-RevenueCat-Webhook-Signature`) can be layered on later. Refunds arrive
  as `REFUND` (or `CANCELLATION` for a non-renewing purchase);
  `REFUND_REVERSED` overturns one.

Exit: a confirmed match where both participants pay unlocks the chat, and each
payment is recorded (RevenueCat-verified) as paid-confirmed.

---

## Phase 10 — Boost Mechanic

Goal: matchmakers can boost a user from the Decision Panel; boosted user's visibility increases until enough new likes arrive.

### Backend
- [ ] `boosts` table (user, started_by, started_at, target_likes_threshold, state)
- [ ] Boost insertion into the discovery query (boosted users surface earlier)
- [ ] Threshold check job — when boost target reached, return user to front of queue
- [ ] Boost expiry (time-based fallback if threshold not reached)
- [ ] **(OPEN)** Daily / weekly boost budget per matchmaker
- [ ] **(OPEN)** Max active boosts per user

### Yentl Matchmaker
- [ ] Boost action in Decision Panel
- [ ] Boost confirmation modal with rationale text
- [ ] Boost history per user

### Yentl
- [ ] No visible UI — boost is silent to users

Exit: matchmaker boosts a user, that user's likes-received accelerates, threshold triggers re-entry to the queue.

---

## Phase 11 — Safety, Moderation, Observability

Goal: ship-safe basics. Some items here can be pulled forward and run alongside earlier phases.

- [ ] In-app reporting flow (Yentl): report a profile, report a message
- [ ] Block another user
- [ ] Yentl Matchmaker moderation queue for reports
- [ ] Bans and soft suspensions
- [ ] Sentry integration in both apps (crashes)
- [ ] PostHog (or similar) integration for funnel analytics
- [ ] Server-side structured logging (Supabase logs + edge function logging)
- [ ] Backup and restore drill on Supabase
- [ ] GDPR: data export endpoint, data deletion endpoint
- [ ] Age verification at signup (18+)
- [ ] Terms of service + privacy policy pages
- [ ] App Store assets — screenshots, description, privacy nutrition labels, age rating

Exit: ready to submit both apps to the App Store with safety, legal, and observability in place.

---

## Phase 12 — Profile Approval Pipeline (Full)

Goal: replace the MVP mock from Phase 3 with the full approval flow. This is a hard gate before any outside-user beta and before App Store submission — Apple reviewers check UGC moderation, and you need at least photo AI screening live before any untrusted user uploads content.

### Backend
- [ ] AI screening edge function: photos through moderation API (NSFW, faces present, single person)
- [ ] AI screening edge function: text through moderation (slurs, profanity, contact info)
- [ ] AI verdict storage with reasons
- [ ] Approval transition logic with audit trail (who, when, why)
- [ ] Flip `profile_approval_enabled` flag to `true`

### Yentl Matchmaker
- [ ] Approval queue list view (sorted by submission time)
- [ ] Approval detail screen — full profile + AI flags + approve / reject buttons
- [ ] Rejection reason entry (free text + canned reasons)

### Yentl
- [ ] "Profile under review" state UI
- [ ] "Profile rejected" state UI with reason and edit-and-resubmit flow

### Data migration
- [ ] Retroactively run every profile created during MVP through the new approval flow before opening to outside users

Exit: every new profile goes through AI + matchmaker review before going live; existing profiles have been retroactively reviewed; App Store submission is unblocked.

---

## Phase 13 — Beta & Launch

- [ ] Internal alpha — team only, on TestFlight
- [ ] Onboard ~3 matchmakers for closed beta
- [ ] Closed beta — invite-only users in one launch city
- [ ] Iterate on Decision Panel UX based on matchmaker feedback
- [ ] Calibrate attractiveness rating across matchmakers
- [ ] Public TestFlight beta
- [ ] App Store submission (Yentl + Yentl Matchmaker as separate entries)
- [ ] Launch in one city

Exit: live in the App Store, first paying date completed.

---

## Cross-cutting concerns

These don't fit neatly in one phase and should be tracked separately:

- **Matchmaker hiring & calibration** — recruiting, training, agreement on rating standards. Starts during Phase 3.
- **Cold-start liquidity** — how the first 500 users land on the platform. Likely a manual outreach effort starting before Phase 12.
- **Pricing experiments** — fee amount, who pays. Needs a starting number for Phase 9; refine post-launch.

---

## Open decisions still to resolve

These appear across the scope and gate specific tasks above:

1. Who pays the per-date fee — one side, both, or split
2. The fee amount
3. Anti-gaming policy for confirm-then-ghost
4. Refund / dispute policy
5. Boost threshold and per-user / per-matchmaker boost limits
6. Candidate ordering after the "liked-you" pool is exhausted
7. Queue alternation behavior under a skewed M/F ratio
8. Chat lifecycle (archive rules)
9. Apple IAP eligibility for the date fee (blocker for Phase 9)
