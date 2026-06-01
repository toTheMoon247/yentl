# Releases

Milestone-based version history for Yentl. Each entry is a **significant, tested
checkpoint** — a stable, verified state of the project — not a per-commit log.
Every entry has a matching annotated Git tag, so any milestone is a clean
rollback point if later work breaks something.

## Conventions

- **Tags are annotated and semver, pre-1.0:** `v0.MINOR.0`. The minor number
  bumps once per milestone. `v1.0.0` is reserved for the first App Store launch
  (Phase 13).
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
