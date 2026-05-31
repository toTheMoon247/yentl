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
