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
- `project-manager-log.md` — the running project journal. **The newest entry is the current status + what's next — read it to resume where we left off.** (Updated once per session, at session end, so mid-session live state may be ahead of it; topic docs like `docs/app-store-submission-kit.md` §0 hold the to-the-minute status.)

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

All three targets build: the shared Swift package and both Xcode apps.

```bash
cd shared && swift build && swift test

xcodebuild build -scheme Yentl -project apps/yentl/Yentl.xcodeproj \
  -destination 'generic/platform=iOS Simulator'
xcodebuild build -scheme YentlMatchmaker \
  -project apps/yentl-matchmaker/YentlMatchmaker.xcodeproj \
  -destination 'generic/platform=iOS Simulator'
```

Use `generic/platform=iOS Simulator` for build checks — it matches CI and, unlike a
named device, does not break when Xcode updates retire a simulator. (A `name=iPhone 16`
destination was documented here until 2026-07-21 and failed once Xcode shipped the
iOS 26.5 runtime with only iPhone 17-family devices.) When you need to *run* the app,
pick a concrete device from `xcrun simctl list devices available`.

Both `.xcodeproj`s use Xcode **file-system-synchronized groups** — a `.swift` file
dropped in the app folder is compiled automatically, with no project-file edit.

`.github/workflows/ci.yml` runs these on `macos-15` runners on every PR and push to `main`.

## Live environment and safety rails

⚠️ **The Supabase MCP server has write access to the live project** (`--project-ref=kegkaerpusgwgfjjrxha` — the same ref hardcoded in `shared/Sources/YentlShared/Environment.swift`). There is no separate staging database. Anything applied through it — migrations, `execute_sql`, function changes — hits the real schema, the real seed users, and real match rows.

- **Before schema changes, take a snapshot.** Backups live outside the repo in `~/Projects/yentl-backups/` (they contain user data and must never be committed). Take one with `supabase db dump --linked -f <path>` plus `--data-only` for rows. Requires Docker Desktop running — `supabase db dump` shells out to `pg_dump` in a container.
- **Never `drop` a table, type, or function on the live project** without explicit confirmation from the user first.
- **`baseline-pre-autonomous-2026-07-21`** is the tagged pre-autonomous-build state, with a matching DB snapshot from the same day. It is a rollback point, not a release — see `RELEASES.md` for why the `v0.x` line was deliberately not advanced.

Other MCP servers configured: `xcodebuild` (build/simulator/UI automation/screenshots) and `context7` (current library docs). MCP servers added mid-session are only picked up on session start. All three are registered at **user scope** (`~/.claude.json`), so they load in every project on this machine — the Supabase one stays pinned to Yentl's `--project-ref` regardless.

### Permissions (workspace-scoped)

Permissions live in two **project** files and deliberately never in `~/.claude/settings.json` — they are Yentl's rules, not machine-wide ones, so other projects are unaffected:

| File | Committed? | Holds |
|---|---|---|
| `.claude/settings.json` | yes | the generic allow / ask / deny rules |
| `.claude/settings.local.json` | no (gitignored) | machine-specific paths only |

The split exists because this repo is **public**: absolute paths containing a home directory stay in the gitignored file.

Shape of the rules, and the reasoning that matters:

- **Allowed without prompting:** `xcodebuild`, `xcrun`, `swift build/test/package`, everyday `git`, *local* Supabase (`start`, `stop`, `test`, `db reset`, `db dump`, `migration list/new`), read-only `gh`, read-only shell utilities, the `xcodebuild`/`context7` MCP tools, and the read-only Supabase MCP tools.
- **Always prompts (`ask`):** `supabase db push`, `mcp__supabase__apply_migration`, `deploy_edge_function`, force-push, `git reset --hard`, `git rebase`. These are the operations that change the live database or rewrite history — the safety rails above are worthless if an autonomous run can sail through them unprompted.
- **Denied outright:** `sudo`, `rm -rf` of `/`, `~` or dotfiles, `curl | sh`, macOS system administration (`diskutil`, `launchctl`, `defaults write`), and reads of `~/.ssh` / `~/.aws`.
- **Deliberately excluded from the allowlist:** `python3`, `osascript`, `npx`, and `gh api` — each is "run anything" or "write to GitHub" wearing a narrow disguise. They still work; they just ask first.

One residual risk worth knowing: `mcp__supabase__execute_sql` **is** allowed, because dev helpers and queries use it constantly — but it can technically run `DROP`. The "never drop without confirmation" rule above is therefore a convention, not something the permission layer enforces.

Rules are read at session start; edits to them need a restart to take effect.

Some setup steps are dashboard-only and cannot be done through any API — enabling **pg_cron** (Database → Extensions) and allowlisting the **redirect URLs** `yentl://auth-callback` and `yentl-matchmaker://auth-callback` (Authentication → URL Configuration). Stop and ask the user rather than trying to automate these.

## Tech stack (summary)

Swift + SwiftUI on iOS 17+, Supabase (Postgres + Auth + Storage + Edge Functions), Stream Chat for messaging, OneSignal for push, Apple IAP for the per-match unlock fee ("Unlock your match" — see `docs/monetization-model.md`). Full table in `docs/tech-stack.md`.

## Design decisions worth remembering

Non-obvious choices recorded across the docs:

- **Monetization is per-confirmed-date fee** via Apple IAP — not subscription. Apple's stance on real-world service fees is the blocking open question for Phase 9.
- **Profile approval is mocked at MVP and built fully in Phase 12** before App Store submission. Phase 3 was folded into Phase 4 (2026-06-03): its only real work is the `profile_review_state` column (default `live`) + `profile_approval_enabled` flag, added in Phase 4 where discovery first needs them. Do not implement Phase 12 work early.
- **Match confirmation: ignored = rejected.** A 24-hour non-response drops the user in the queue identically to an explicit reject.
- **Attractiveness rating is matchmaker-assigned**, not algorithmic, and is captured on first Decision Panel encounter (Phase 5) rather than at approval — because Phase 3 is mocked.
- **MVP is heterosexual matching only**; the queue alternates M/F. Same-sex support is deferred.
- The Profile Approval Workflow step was renamed from "Yentl Review" → **"Matchmaker Review"** to avoid clashing with the consumer app name.
- **Apple Developer Program: the user confirmed on 2026-07-22 that they have it.** This was previously the project's longest-lead-time blocker, deferred to Phase 8 (Push Notifications) — that deferral is now resolved, so do not keep flagging enrollment. **Real native Sign in with Apple is now implemented** (2026-07-23) — `AuthService.signInWithApple()` runs `ASAuthorizationController` and exchanges the identity token via Supabase `signInWithIdToken`; the "Sign in with Apple" capability/entitlement is on both apps. It still needs two one-time dashboard steps to function at runtime: the capability enabled on the App ID(s) in the Apple Developer console, and the Apple provider enabled in Supabase (bundle id as an authorized client). Google remains the other working path.

## Git and commit conventions

- Default branch is `main`. Pushing files under `.github/workflows/` requires a `gh` token with the `workflow` scope (already granted to this user).
- The user reviews history actively and has previously asked to split a commit retroactively — prefer small, single-purpose commits and confirm before force-pushing.
- End commit messages with a `Co-Authored-By:` line for the assisting model (e.g. `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`).

## Milestone-based versioning

When the project reaches a **significant, tested checkpoint** (e.g. Google OAuth complete, Authentication complete, Onboarding complete, Profile Creation complete), create an **annotated, semver pre-1.0 Git tag** (`v0.MINOR.0`; `v1.0.0` is reserved for App Store launch) and add a short, newest-first entry to `RELEASES.md`. See that file for the full conventions.

- Tag **only verified states**: CI green on the tagged commit *and* the milestone's behavior exercised (built/run or validated end-to-end).
- **Major milestones only** — routine commits, refactors, and CI tweaks do not get tagged or logged.
- These tags are the project's rollback points; the goal is always having a clear last-known-good state to return to.
