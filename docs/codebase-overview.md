# Yentl Codebase Overview

A plain-language tour of the repo for someone new to the project: the
architecture, the major building blocks, and how each part works.

> Snapshot as of 2026-06-02 (Phase 1 complete — auth, role gate, session/logout,
> onboarding). Keep this current as later phases land.

---

## Table of Contents

1. The Big Picture
2. Repository Layout
3. The `YentlShared` Swift Package — file by file
4. The Two iOS Apps
5. The Supabase Backend
6. CI Pipeline
7. What is Real vs. Stubbed Right Now
8. Where to Start as a Newcomer

---

## 1. The Big Picture

Yentl is a dating platform built around human matchmakers rather than pure algorithms. The two key ideas that drive every architectural decision are:

- **Two separate apps, one backend.** Regular users use the Yentl consumer app. Professional matchmakers use Yentl Matchmaker, an internal-only tool. Both apps talk to the same Supabase database and auth system.
- **The matchmaker is the gatekeeper.** Users can sign up, build profiles, and swipe — but no match is ever created by an algorithm. A matchmaker must create it manually through the Decision Panel in the Yentl Matchmaker app.

The platform is currently between Phase 1 and Phase 2 of a 13-phase implementation plan. Phase 1 (authentication + onboarding) is complete. Phase 2 (profile creation) has not started.

### Architecture at a glance

```
┌──────────────────────────────────┐   ┌──────────────────────────────────────┐
│       Yentl (consumer app)       │   │     Yentl Matchmaker (internal app)  │
│    apps/yentl/                   │   │    apps/yentl-matchmaker/            │
│                                  │   │                                      │
│  YentlApp  ──> ContentView       │   │  YentlMatchmakerApp ──> ContentView  │
│              (routes on auth      │   │                   (routes on auth     │
│               state + onboarding)│   │                    state + role)      │
└─────────────┬────────────────────┘   └─────────────┬────────────────────────┘
              │                                      │
              │  both import                         │  both import
              ▼                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      YentlShared  (shared/ Swift package)                   │
│                                                                             │
│  AuthService   Backend   UserRole   AppEnvironment   DesignTokens           │
│  YentlAuthFlow   SignOutButton   YentlShared (version marker)               │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
                                       │  supabase-swift SDK
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Supabase (cloud backend)                             │
│                                                                             │
│  Auth (Google OAuth, Apple stub)     public.users table + RLS               │
│  Postgres database                   Edge Functions (empty, Phase 7+)       │
│  Storage (empty, Phase 2+)           Realtime (not yet used)                │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Dependency direction:** Both iOS apps depend on `YentlShared`. `YentlShared` depends on the `supabase-swift` SDK. Neither app depends on the other.

---

## 2. Repository Layout

```
yentl/
├── apps/
│   ├── yentl/                    The consumer iOS app (Xcode project)
│   │   ├── Yentl.xcodeproj/
│   │   └── Yentl/
│   │       ├── YentlApp.swift        @main entry point
│   │       ├── ContentView.swift     Root view + routing (auth + onboarding)
│   │       ├── OnboardingFlow.swift  Post-sign-in onboarding flow
│   │       └── Info.plist            Registers the yentl:// URL scheme
│   └── yentl-matchmaker/         The internal matchmaker iOS app
│       ├── YentlMatchmaker.xcodeproj/
│       └── YentlMatchmaker/
│           ├── YentlMatchmakerApp.swift  @main entry point
│           ├── ContentView.swift         Root view + routing + role gate
│           └── Info.plist                Registers yentl-matchmaker:// URL scheme
│
├── shared/                       YentlShared Swift package
│   ├── Package.swift             Declares the package; pulls in supabase-swift
│   ├── Sources/YentlShared/      All shared source files
│   └── Tests/YentlSharedTests/   One test today (version-not-empty smoke test)
│
├── supabase/
│   ├── config.toml               Local Supabase CLI config (project_id = "yentl")
│   ├── migrations/               SQL migration files, applied in filename order
│   │   ├── 20260530202003_users_table_and_rls.sql   Phase 1: users + RLS
│   │   └── 20260601202049_onboarding_fields.sql     Phase 1: onboarding consent
│   └── functions/                Edge Functions — empty at Phase 1
│
├── docs/
│   ├── project-scope.md          Product vision, two-app architecture, monetization
│   ├── tech-stack.md             Technology choices table
│   ├── implementation-plan.md    Phase-by-phase task list — the authoritative plan
│   └── codebase-overview.md      This document
│
├── RELEASES.md                   Milestone version history (tagged rollback points)
├── project-manager-log.md        Daily journal of progress
│
└── .github/
    └── workflows/
        └── ci.yml                Four CI jobs: shared package, two iOS apps, SwiftLint
```

Key things to notice:

- `apps/` contains two completely separate Xcode projects. They are siblings, not nested.
- `shared/` is a local Swift package that both Xcode projects reference. It is the only place shared code lives.
- `supabase/` is managed by the Supabase CLI. The `config.toml` describes the local dev environment; `migrations/` files are applied to both local and remote databases.
- `docs/` is the product and engineering spec. If you want to understand *why* something was built a certain way, start there. `implementation-plan.md` is the single most useful document for understanding what has been done and what is next.

---

## 3. The `YentlShared` Swift Package — File by File

This package lives at `shared/`. It is the shared library that both apps import. It has exactly one external dependency: the official `supabase-swift` SDK (version 2.x), declared in `Package.swift`.

### 3.1 `YentlShared.swift` — Version marker

A namespace (`public enum YentlShared`) holding a single static `version` string. CI smoke-tests that it is non-empty. It will also be useful once both apps ship: you can assert at runtime that they are linked against the same version of the shared library.

### 3.2 `Environment.swift` — Environment configuration

```
AppEnvironment
  .dev       ← default when YENTL_ENV is unset
  .staging   ← not yet configured (will fatalError if hit)
  .prod      ← not yet configured (will fatalError if hit)
```

Answers "which Supabase project should I connect to?" Reads `YENTL_ENV` from the host app's `Info.plist`; defaults to `.dev` for local development. Each case provides a `supabaseURL` and `supabasePublishableKey`.

The dev URL and key are hardcoded here for now (intentional Phase 1 simplicity). The Supabase publishable (anon) key is safe to commit because Row Level Security on the database controls what it can access — it is not a secret. Staging/prod credentials will move out of source control before those environments are set up.

### 3.3 `Backend.swift` — The single Supabase client

Exposes one lazily-initialized singleton, `Backend.supabase`. It reads `AppEnvironment.current` for the URL/key, then constructs the `SupabaseClient` with three options pinned explicitly:

- **Keychain storage** for the session — the user stays logged in across cold launches.
- **`autoRefreshToken: true`** — the JWT is refreshed silently before expiry.
- **`emitLocalSessionAsInitialSession: true`** — on launch, surface the cached session immediately rather than waiting for a network round-trip (the app appears logged-in instantly, even offline).

These are pinned rather than left to SDK defaults so a future SDK change can't silently sign everyone out. Both apps use `Backend.supabase` exclusively — they never construct their own client.

### 3.4 `UserRole.swift` — The role enum

```swift
public enum UserRole: String, Codable {
    case user        // regular consumer
    case matchmaker  // internal staff
    case admin       // internal staff + elevated permissions
}
```

A direct mirror of the `public.user_role` Postgres enum. The `String` raw value encodes/decodes to the exact strings the database sends. They must be kept in sync manually — there is no code generation. The convenience property `isStaff` returns `true` for `matchmaker`/`admin`; the Matchmaker app uses it to gate access.

### 3.5 `AuthService.swift` — Authentication state and operations

The most important file in the package. An `@Observable` class that both apps inject into their SwiftUI environment and read throughout the UI.

```swift
public enum AuthState {
    case loading      // first launch, before we know if there's a session
    case signedOut    // no active session
    case signedIn(user: User)  // active session
}
```

`AuthService.state` is the single source of truth for whether the user is authenticated. All routing decisions in both apps derive from it.

**Initialization:** `AuthService` is a singleton (`AuthService.shared`). On creation it fires an async `Task` running `observeAuthChanges()`, which (1) hydrates initial state from the cached Keychain session, then (2) enters a `for await` loop over `Backend.supabase.auth.authStateChanges` so Swift state stays in sync with the backend session for the app's lifetime.

**Operations:**
- `signInWithGoogle(redirectURL:)` — opens an `ASWebAuthenticationSession`; after Google authenticates, the redirect returns to the app's custom URL scheme, Supabase issues a JWT, and the change stream updates `state` automatically.
- `signInWithApple()` — **currently a stub** that throws `AuthError.appleSignInPendingDeveloperAccount`. Requires Apple Developer Program enrollment (deferred to Phase 8). The button is shown but tapping it surfaces an explanatory error.
- `signOut()` — clears the Keychain session and triggers `.signedOut`.
- `fetchCurrentUserRole()` — reads the caller's `role` from `public.users` (used by the Matchmaker app).
- `isOnboardingComplete()` / `completeOnboarding()` — read `public.users.onboarding_completed_at`, and record consent via the `complete_onboarding` RPC (used by the consumer app).

### 3.6 `YentlAuthFlow.swift` — The sign-in screen

A reusable SwiftUI view rendering the sign-in screen for both apps. It takes an `AuthFlowConfig` (app title, tagline, OAuth redirect URL). Two prebuilt configs exist: `.yentl` (`yentl://auth-callback`) and `.matchmaker` (`yentl-matchmaker://auth-callback`). Renders "Continue with Apple" and "Continue with Google" buttons; both disable while a request is in flight. The Apple button is always visible but always errors right now (stub).

### 3.7 `SignOutButton.swift` — Shared sign-out control

A tiny reusable button that reads `AuthService` from the environment and calls `signOut()`, disabling itself while in flight. Important detail: `signOut()` clears the local Keychain session *before* the network revoke completes, so the hosting view routes away immediately — and even if the network call fails (offline), the user is still signed out locally. Getting stuck on a sign-out screen offline would be worse than the rare case where the server token isn't formally revoked.

### 3.8 `DesignTokens.swift` — Cross-app design constants

A namespace with nested enums for spacing, corner radii, colors (`Palette`), and typography. Both apps use values like `DesignTokens.Spacing.lg`. These are Phase 0 placeholders; when real brand design lands, changing it here updates both apps at once.

### How the shared files fit together

```
AppEnvironment  ──reads──>  Backend.supabase  ──used by──>  AuthService
                                                                  │
                              UserRole  <──fetched by──────────────┤
                                                                  │
                         YentlAuthFlow  ──calls methods on──────────┤
                         SignOutButton  ──calls methods on──────────┘
                         DesignTokens  ──used by──>  the shared views
```

The two apps never talk to `Backend.supabase` directly — all Supabase access goes through `AuthService`. (Later phases will add other service classes that also call `Backend.supabase` for domain operations like profiles, swipes, and matches.)

---

## 4. The Two iOS Apps

### 4.1 Yentl (consumer app) — `apps/yentl/Yentl/`

**Entry point (`YentlApp.swift`):** creates one `AuthService.shared` and injects it into the SwiftUI environment so every view can read it with `@Environment(AuthService.self)`.

**Root view (`ContentView.swift`):** routes on `auth.state`, then on onboarding status:

```
auth.state
  ├── .loading   → spinner
  ├── .signedOut → YentlAuthFlow(config: .yentl)
  └── .signedIn  → check onboarding status (.task)
                     ├── (checking) → "Getting things ready…"
                     ├── complete   → SignedInHomeView (placeholder; Phase 2)
                     ├── incomplete → OnboardingFlow
                     └── error      → retry view
```

Because `AuthService` is `@Observable`, SwiftUI re-renders automatically when state changes — signing in/out transitions screens with no manual navigation code.

**`OnboardingFlow.swift`:** the post-sign-in gate, shown once when `onboarding_completed_at` is null. Three steps — **Welcome → privacy note → terms/consent + 18+ confirmation** (both toggles required to continue). On completion it calls `AuthService.completeOnboarding()` (which records consent server-side) and routes to the home screen. Full Terms/Privacy pages and stricter age verification come in Phase 11; this is the MVP consent step.

**`Info.plist`:** registers the `yentl://` URL scheme so Google's OAuth redirect returns to the app.

### 4.2 Yentl Matchmaker (internal app) — `apps/yentl-matchmaker/YentlMatchmaker/`

Same entry-point structure. The Xcode product is `YentlMatchmaker` (no space), but the display name is "Yentl Matchmaker".

**Root view (`ContentView.swift`) — the role gate:** after confirming `.signedIn`, it fetches the user's role from the database and routes again:

```
.signedIn → fetch role (.task(id: signedInUserID))
              ├── (fetching)            → "Checking access…"
              ├── role.isStaff == true  → MatchmakerHomeView (placeholder; Phase 5)
              ├── role.isStaff == false → AccessPendingView
              └── error                 → RoleFetchErrorView (with retry)
```

The `.task(id:)` keys on the signed-in user id so the role re-fetches when the user changes (sign out → sign in as someone else), preventing a stale cached role.

**Matchmaker promotion today** is a manual SQL `UPDATE` in Supabase Studio — there is no admin UI yet (acceptable for MVP).

**`Info.plist`:** registers `yentl-matchmaker://` — a distinct scheme so iOS routes the OAuth callback to this app, not the consumer app.

---

## 5. The Supabase Backend

### 5.1 Migration: `20260530202003_users_table_and_rls.sql`

- **`user_role` enum** (`'user'`, `'matchmaker'`, `'admin'`) — mirrors the Swift `UserRole`.
- **`public.users` table:** `id` (FK to `auth.users`, cascade delete), `role` (default `'user'`), `created_at`, `updated_at`. Supabase Auth owns `auth.users`; `public.users` is the app's extension of it, sharing the same UUID.
- **`on_auth_user_created` trigger:** when Supabase Auth inserts into `auth.users` (first sign-in), this auto-inserts the matching `public.users` row. The app never creates it manually.
- **`updated_at` trigger:** refreshes `updated_at` on every row update.
- **`is_matchmaker_or_admin()`** — a `security definer` helper (runs as creator, not caller) used inside RLS to avoid recursive RLS evaluation on the caller's own row.
- **RLS policies:** `users_select_own` (any authed user reads their own row) and `users_select_all_for_staff` (staff read all rows — needed for the Decision Panel later). No INSERT policy (trigger handles it), no UPDATE policy (role changes go through the service role), no DELETE policy (cascades from `auth.users`).

### 5.2 Migration: `20260601202049_onboarding_fields.sql`

- Adds `terms_accepted_at`, `age_confirmed_at`, `onboarding_completed_at` (all nullable `timestamptz`) to `public.users` — the account-scoped consent record.
- **`complete_onboarding()` RPC:** a `security definer` function that stamps those three timestamps for `auth.uid()` only. Using an RPC (rather than opening a self-UPDATE RLS policy) means a user can never touch their own `role` — role escalation is impossible by construction. Execute is granted to `authenticated` only.
- The consumer app's onboarding gate reads `onboarding_completed_at` to decide whether to show the flow.

### 5.3 `supabase/config.toml`

Supabase CLI config for local dev: `project_id = "yentl"`; DB on `54322`, API on `54321`, Studio on `54323`; Postgres `major_version = 17`. Apple OAuth is `enabled = false` (consistent with the Apple account deferral). Email/password auth is enabled in config but the apps intentionally use only OAuth. `supabase/functions/` is empty — Edge Functions arrive in Phases 7 (Stream Chat tokens) and 9 (IAP receipt validation).

---

## 6. CI Pipeline — `.github/workflows/ci.yml`

Runs on every pull request and every push to `main`. Four parallel jobs on `macos-15` runners with the latest Xcode; a PR is blocked if any fails.

1. **`shared-package`** — `swift build` + `swift test` on `YentlShared` (no Xcode needed). One test today: the version-not-empty smoke test.
2. **`ios-yentl`** — `xcodebuild build -scheme Yentl -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`. Code signing is skipped (no certificate on the runner). Uses `-scheme` (with a committed shared scheme) so SwiftPM resolves the transitive package graph correctly.
3. **`ios-yentl-matchmaker`** — same, for the matchmaker app.
4. **`swiftlint`** — installs SwiftLint via Homebrew and lints the repo. Serious (error-level) violations fail the job; the line-length limit is strict.

---

## 7. What is Real vs. Stubbed Right Now

| Feature | Status | Notes |
|---|---|---|
| Google Sign-In | **Working end-to-end** | Validated in simulator |
| Apple Sign-In | **Stub — always throws** | Blocked on Apple Developer Program ($99/yr). Button visible but non-functional. Phase 8. |
| Persistent session (Keychain) | **Working** | Survives cold restarts |
| Role-based access gate (Matchmaker) | **Working** | `user` → Access Pending; staff → home |
| Matchmaker role promotion | **Manual SQL only** | No admin UI; done via Supabase Studio |
| Onboarding flow (consumer) | **Working** | Welcome → privacy → terms + 18+, recorded server-side |
| `SignedInHomeView` (consumer) | **Placeholder** | "Phase 2 work goes here" |
| `MatchmakerHomeView` | **Placeholder** | "Decision Panel goes here in Phase 5" |
| Profile creation | **Not started** | Phase 2 |
| Profile approval | **Not started** | Mocked in Phase 3, real in Phase 12 |
| Discovery / swiping | **Not started** | Phase 4 |
| Decision Panel (matchmaker core UX) | **Not started** | Phase 5 |
| Chat | **Not started** | Phase 7 |
| Push notifications | **Not started** | Phase 8 (also needs Apple Developer account) |
| Payments | **Not started** | Phase 9; open Apple-policy question |
| `staging` / `prod` Supabase | **Not configured** | `fatalError` if hit; only `dev` is wired up |

---

## 8. Where to Start as a Newcomer

**Read first, in order:**

1. `docs/project-scope.md` — understand the product before touching code
2. `docs/implementation-plan.md` — where the project is and where it's going
3. `shared/Sources/YentlShared/AuthService.swift` — controls all auth state
4. `shared/Sources/YentlShared/Backend.swift` — the single Supabase connection
5. `apps/yentl-matchmaker/YentlMatchmaker/ContentView.swift` — the most complex routing today
6. `supabase/migrations/` — the database shape

**Mental model:** `AuthService.state` is the master switch. Every screen in both apps is a function of that value; when it changes, SwiftUI re-renders the root `ContentView` and routes automatically. The consumer app layers an onboarding check on top of `.signedIn`; the Matchmaker app layers a role check.

**The one thing that trips everyone up:** Apple Sign-In *looks* implemented (the button and method exist) but always errors by design. Don't try to "fix" it — it needs an Apple Developer account, App ID, and entitlements that don't exist yet. The stub is replaced in Phase 8.

---

*All paths are relative to the repo root. This document is regenerated/updated as the codebase evolves — if it disagrees with the code, trust the code and update this file.*
