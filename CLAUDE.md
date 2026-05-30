# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Yentl is a human-centered dating platform — professional matchmakers, not pure algorithms, decide who matches. The product is **two iOS apps** sharing one Supabase backend:

| App | Folder | Bundle ID | Xcode product |
|---|---|---|---|
| **Yentl** (public consumer app) | `apps/yentl/` | `com.yentl.app` | `Yentl` |
| **Yentl Matchmaker** (internal) | `apps/yentl-matchmaker/` | `com.yentl.matchmaker` | `YentlMatchmaker` |

Naming note: these were renamed from "Dating App" and "Yentl App" — do not reintroduce the old names. "Yentl" is both the company and the consumer app name; disambiguate from context.

## Authoritative docs (read these first)

- `docs/project-scope.md` — product scope, two-app architecture, monetization, Decision Panel design, elevator pitch.
- `docs/tech-stack.md` — chosen stack table.
- `docs/implementation-plan.md` — phase-by-phase task breakdown. **Confirm the current phase here before starting work.**

## Repository layout

```
apps/yentl/               Consumer iOS app (Xcode project to be created — see folder README)
apps/yentl-matchmaker/    Internal matchmaker iOS app (same)
shared/                   YentlShared Swift package — local dependency of both apps
supabase/migrations/      SQL migrations (empty at Phase 0)
supabase/functions/       Edge Functions (empty at Phase 0)
docs/                     Product and implementation documentation
.github/workflows/        CI
```

## Build and test

The shared Swift package is the only buildable artifact today (the two Xcode projects have not been created yet — see per-app READMEs for the Xcode wizard walkthrough).

```bash
cd shared
swift build
swift test
```

`.github/workflows/ci.yml` runs the same on a `macos-14` runner on every PR and push to `main`.

## Tech stack (summary)

Swift + SwiftUI on iOS 17+, Supabase (Postgres + Auth + Storage + Edge Functions), Stream Chat for messaging, OneSignal for push, Apple IAP for the per-confirmed-date fee. Full table in `docs/tech-stack.md`.

## Design decisions worth remembering

Non-obvious choices recorded across the docs:

- **Monetization is per-confirmed-date fee** via Apple IAP — not subscription. Apple's stance on real-world service fees is the blocking open question for Phase 9.
- **Profile approval is mocked at MVP (Phase 3)** and built fully in Phase 12 before App Store submission. Do not implement Phase 12 work inside Phase 3.
- **Match confirmation: ignored = rejected.** A 24-hour non-response drops the user in the queue identically to an explicit reject.
- **Attractiveness rating is matchmaker-assigned**, not algorithmic, and is captured on first Decision Panel encounter (Phase 5) rather than at approval — because Phase 3 is mocked.
- **MVP is heterosexual matching only**; the queue alternates M/F. Same-sex support is deferred.
- The Profile Approval Workflow step was renamed from "Yentl Review" → **"Matchmaker Review"** to avoid clashing with the consumer app name.

## Git and commit conventions

- Default branch is `main`. Pushing files under `.github/workflows/` requires a `gh` token with the `workflow` scope (already granted to this user).
- The user reviews history actively and has previously asked to split a commit retroactively — prefer small, single-purpose commits and confirm before force-pushing.
- End commit messages with a `Co-Authored-By:` line for the assisting model (e.g. `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`).
