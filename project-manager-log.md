# Project Manager Log

A daily journal of what we shipped, where the project sits, and what's next.

The product scope (`docs/project-scope.md`) and the phase-by-phase plan (`docs/implementation-plan.md`) were drafted across 2026-05-28 and 2026-05-29 — those days were pure planning/decision work and aren't counted here. **Day 1 starts with the first build session, 2026-05-30.**

A "day" here is one work session, not one calendar day. If a session runs past midnight, the calendar rolls but the day in this log doesn't.

---

## Day 1 — 2026-05-30 → 2026-05-31

**Today.** Built **Phase 0 foundations**, shipped most of **Phase 1**, and got Google Sign-In validated end-to-end.

Phase 0 — foundations:

- Monorepo layout (`apps/`, `shared/`, `supabase/`, `docs/`, `.github/`), Swift/iOS `.gitignore`, GitHub Actions CI (green at the start of the session), SwiftLint config.
- `YentlShared` Swift package: `AppEnvironment`, `DesignTokens`, `Backend.supabase`.
- Both Xcode projects created and linked to `YentlShared`, bundle IDs set, OAuth URL schemes registered (`yentl://`, `yentl-matchmaker://`).

Phase 1 — backend + auth scaffolding:

- Supabase dev project created, CLI installed and linked.
- First migration shipped: `public.users` + `user_role` enum + auto-trigger from `auth.users` + RLS policies.
- `AuthService`, `UserRole`, `YentlAuthFlow` in `YentlShared`.
- Both apps wired to route on `AuthState`; Matchmaker has the role gate.
- Locked the **Apple Developer Program deferral** to right before Phase 8 (push). Reminder locked in three places (plan, `CLAUDE.md`, persistent memory).

Phase 1 — validation:

- **Google Sign-In working end-to-end** in the simulator: Google approval → Supabase callback → `auth.users` row → trigger fires → `public.users` row → app shows signed-in state.
- Chased a "Safari → localhost" redirect failure; root cause was missing app redirect URLs in Supabase's URL Configuration. Added `yentl://auth-callback` and `yentl-matchmaker://auth-callback` to the allowed list. Memory + checklist saved so this trap doesn't recur.

CI:

- Red on the two iOS app build jobs. GitHub's `macos-15` runners ship Xcode 26.3 vs. local 26.5, and the strict explicit-module driver flags an import inside Supabase's `swift-clocks` transitive dependency. Two workarounds tried (git default-branch, `SWIFT_ENABLE_EXPLICIT_MODULES=NO`); neither has worked yet.

**Progress.** From "docs only" to "two iOS apps that build, with Phase 1 consumer-side auth flow validated end-to-end" — including the `public.users` trigger we'll rely on in every later phase. Matchmaker side is coded but not observed working yet. CI is the meaningful outstanding blocker.

**Steps for tomorrow.**

- Validate the Matchmaker role gate end-to-end: sign in via the Matchmaker app → see "Access pending" → promote your role in Studio → sign in again → confirm `MatchmakerHomeView`.
- Fix CI: try bumping Supabase to its latest version so SwiftPM picks a newer `swift-clocks` compatible with `xctest-dynamic-overlay` 1.9.
- Finish Phase 1: build the onboarding screens (welcome / privacy / terms acceptance) for the Yentl app.
- Then start Phase 2 (profile creation + storage).
