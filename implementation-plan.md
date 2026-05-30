# Implementation Plan

This plan breaks Yentl's MVP into small, sequenced tasks grouped by phase. Each phase has a clear exit criterion. Phases are mostly sequential — later phases assume earlier ones are done.

## Conventions

- "Dating App" = the iOS app users see.
- "Yentl App" = the iOS app matchmakers use.
- "Backend" = Supabase (Postgres + Auth + Storage + Edge Functions).
- Open decisions are tagged **(OPEN)** and need answers before the task can ship.

---

## Phase 0 — Foundations

Goal: a clean, deployable skeleton for both iOS apps and the backend, with CI in place.

- [ ] Create Supabase project (dev) and capture connection details
- [ ] Set up Apple developer assets (App IDs, certificates, provisioning) for both apps
- [ ] Initialize the Dating App Xcode project (SwiftUI, iOS 17+ target)
- [ ] Initialize the Yentl App Xcode project (SwiftUI, iOS 17+ target)
- [ ] Create a shared Swift package for models, API client, and shared utilities
- [ ] Configure SwiftLint and a basic CI pipeline (build + lint on PR) for both apps
- [ ] Set up environment configuration (dev / staging / prod) for both apps and Supabase
- [ ] Create a design tokens file (colors, typography, spacing) shared between both apps

Exit: both apps build, run on simulator, hit a "hello" endpoint on Supabase, CI is green.

---

## Phase 1 — Identity & Auth

Goal: users and matchmakers can sign up, log in, and stay logged in across launches.

### Dating App
- [ ] Onboarding screens — welcome, privacy, terms acceptance
- [ ] Apple Sign-In flow + Supabase Auth handshake
- [ ] Google Sign-In flow + Supabase Auth handshake
- [ ] Persistent session handling and logout
- [ ] Account state model (logged out / no profile / profile pending / profile live / rejected)

### Yentl App
- [ ] Email + password sign-in for matchmakers (allow-listed accounts only)
- [ ] Role-based access check on app launch (block non-matchmakers)
- [ ] Logout

### Backend
- [ ] `users` table with role column (`user` / `matchmaker` / `admin`)
- [ ] Row Level Security policies on `users`
- [ ] Matchmaker invitation flow (admin creates matchmaker account)

Exit: a fresh install can sign up via Apple or Google; a fresh Yentl App install can log in with a pre-provisioned matchmaker account.

---

## Phase 2 — Profile Creation & Storage

Goal: users can complete a profile with photos, bio, prompts, and the hidden matchmaker fields.

### Dating App
- [ ] Profile creation wizard — basics (name, DOB, gender — male/female only at MVP, location)
- [ ] Photo upload UI (multi-photo, reorder, delete)
- [ ] Bio and prompts entry
- [ ] Interests selection
- [ ] Height and income inputs (OPEN: required at signup or optional?)
- [ ] Profile preview screen (what others will see)
- [ ] Profile edit screen post-approval

### Backend
- [ ] `profiles` table schema (public fields + hidden fields)
- [ ] `profile_photos` table with order index
- [ ] Supabase Storage bucket for profile photos, with RLS
- [ ] Image resize / variant generation on upload (thumb, medium, full)
- [ ] Photo deletion + storage cleanup

### Yentl App
- [ ] Profile viewer (mirrors the Dating App profile view, plus hidden matchmaker fields)

Exit: a user can build a full profile in the Dating App; a matchmaker can open that profile in the Yentl App and see both public + hidden fields.

---

## Phase 3 — Profile Approval Pipeline

Goal: every new profile goes through AI screening + matchmaker approval before going live.

### Backend
- [ ] `profile_review_state` enum and column (`draft / pending_ai / pending_review / live / rejected`)
- [ ] AI screening edge function: photos through moderation API (NSFW, faces present, single person)
- [ ] AI screening edge function: text through moderation (slurs, profanity, contact info)
- [ ] AI verdict storage with reasons
- [ ] Approval transition logic with audit trail (who, when, why)

### Yentl App
- [ ] Approval queue list view (sorted by submission time)
- [ ] Approval detail screen — full profile + AI flags + approve / reject buttons
- [ ] Rejection reason entry (free text + canned reasons)
- [ ] Initial attractiveness rating UI (matchmaker assigns at approval; used in Phase 5)

### Dating App
- [ ] "Profile under review" state UI
- [ ] "Profile rejected" state UI with reason and edit-and-resubmit flow

Exit: a brand-new user finishes their profile, the AI screens it, a matchmaker approves it, and the user sees their profile go live.

---

## Phase 4 — Discovery & Likes (Dating App side)

Goal: users can swipe on each other and accumulate "likes received". No matches yet — that comes from the matchmaker.

### Dating App
- [ ] Discovery stack screen (card swiper, photos, basic info)
- [ ] Profile detail view from the stack
- [ ] Like / pass actions
- [ ] "Likes you" inbox
- [ ] Empty states (no one new, "you've seen everyone")

### Backend
- [ ] `swipes` table (from_user, to_user, action, created_at)
- [ ] Discovery query: candidates the user has not yet swiped on, filtered to opposite gender (OPEN: ordering rule — likes-you first, then ?)
- [ ] Index strategy for discovery query at scale
- [ ] "Likes you" query

Exit: two test users can each swipe on each other and the system records likes — but no match is created until a matchmaker creates one.

---

## Phase 5 — Matchmaker Queue & Decision Panel

Goal: the core differentiating UX. Matchmakers see users at the front of the queue and create matches via the swipe-style Decision Panel.

### Backend
- [ ] `matchmaking_queue` table with alternation logic (M / F / M / F)
- [ ] Queue position assignment on profile approval
- [ ] Queue advancement service (next user up)
- [ ] Internal-only fields: attractiveness rating (matchmaker-assigned), height / income / activity percentiles
- [ ] Percentile calculation jobs (nightly or on-demand)
- [ ] Internal notes table (per user, audit-trailed)

### Yentl App
- [ ] Decision Panel — top section (pinned user with hidden fields)
- [ ] Decision Panel — bottom section (candidate viewer)
- [ ] Candidate ordering: users who already liked the pinned user first
- [ ] Candidate ordering after the "liked-you" pool runs out (OPEN: random / proximity / compatibility score?)
- [ ] Profile inspection tap-through (full profile view, back button)
- [ ] Compatibility indicator visuals (bars or heatmap)
- [ ] Internal notes editor on pinned user
- [ ] "Skip user" action (advance queue without matching or boosting)

Exit: a matchmaker can pull up a queued user and browse candidates in the Decision Panel layout exactly as specified in scope.

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

### Dating App
- [ ] Incoming match notification UI
- [ ] Match detail screen (other user's full profile + accept / reject buttons + countdown)
- [ ] Accept / reject actions
- [ ] Outcome screens (confirmed, expired, rejected by the other side)

### Yentl App
- [ ] Match creation confirm-step from Decision Panel
- [ ] Match history view per user
- [ ] Recent matches dashboard

Exit: matchmaker creates a match; ignored = rejected logic plays out correctly in three scenarios (both accept, one rejects, one ignores).

---

## Phase 7 — Chat

Goal: confirmed matches get a private chat channel.

- [ ] Stream Chat integration (auth tokens issued by a Supabase edge function)
- [ ] Channel creation on match confirmation
- [ ] In-app chat UI (Dating App)
- [ ] Chat list / inbox screen
- [ ] Read receipts and typing indicators (Stream native)
- [ ] Block / report in chat
- [ ] Chat lifecycle: archive rules (OPEN: define)

Exit: two test users who both confirm a match can chat in real time.

---

## Phase 8 — Notifications

Goal: users and matchmakers get the right pushes at the right times.

- [ ] OneSignal SDK in both apps
- [ ] Device registration on login, deregistration on logout
- [ ] Push permission prompts in onboarding
- [ ] Notification triggers — match created, match confirmed, match rejected, match expiring soon (e.g. 4h left), new message
- [ ] In-app notification center
- [ ] Per-category notification settings screen

Exit: every match lifecycle event fires a push to the right user with the right deep link.

---

## Phase 9 — Payments (Apple IAP)

Goal: per-confirmed-date fee charged via Apple IAP at the moment both users confirm.

- [ ] **(OPEN, blocking)** Confirm Apple's stance — is a real-world date fee IAP-required or Stripe-eligible? Get this in writing or via Apple Developer support before building.
- [ ] StoreKit 2 product setup in App Store Connect
- [ ] Purchase UI on match-confirmed screen
- [ ] Receipt validation via Supabase edge function
- [ ] Wire up payer logic (OPEN: one side / both / split)
- [ ] Refund / dispute handling (server-side webhook from App Store)
- [ ] Anti-gaming: detect repeat confirm-then-ghost patterns (OPEN: rule definition)
- [ ] Payment history per user

Exit: a confirmed match triggers a successful IAP and the date is recorded as paid-confirmed.

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

### Yentl App
- [ ] Boost action in Decision Panel
- [ ] Boost confirmation modal with rationale text
- [ ] Boost history per user

### Dating App
- [ ] No visible UI — boost is silent to users

Exit: matchmaker boosts a user, that user's likes-received accelerates, threshold triggers re-entry to the queue.

---

## Phase 11 — Safety, Moderation, Observability

Goal: ship-safe basics. Some items here can be pulled forward and run alongside earlier phases.

- [ ] In-app reporting flow (Dating App): report a profile, report a message
- [ ] Block another user
- [ ] Yentl App moderation queue for reports
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

## Phase 12 — Beta & Launch

- [ ] Internal alpha — team only, on TestFlight
- [ ] Onboard ~3 matchmakers for closed beta
- [ ] Closed beta — invite-only users in one launch city
- [ ] Iterate on Decision Panel UX based on matchmaker feedback
- [ ] Calibrate attractiveness rating across matchmakers
- [ ] Public TestFlight beta
- [ ] App Store submission (Dating App + Yentl App as separate entries)
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
