# Autonomous build brief

Single hand-off brief for an autonomous agent continuing Yentl. Written
2026-07-21, immediately after the `baseline-pre-autonomous-2026-07-21` tag.

## Read first

1. `CLAUDE.md` — especially **Live environment and safety rails**. Non-negotiable.
2. `docs/implementation-plan.md` — confirm the current phase before starting.
3. `project-manager-log.md` — Day 11 is the latest entry and states exactly
   where things stand and what is owed.

## Objective

Get both Yentl apps working and carry the implementation plan forward with as
little user intervention as possible. The user provides this one brief and then
steps back; do not wait for steering that will not come. When you genuinely need
a human (see **Stop and ask**), ask concisely, batch requests where you can, and
continue with everything not blocked by the answer.

## Order of work

**1. Prove the build — do this before anything else.**
Both `.xcodeproj` bundles were deleted around 11 Jul and restored from HEAD on
Day 11. They have not been opened or built since. The baseline is therefore a
*known* state, not a known-*good* one. Build all three targets:

```bash
cd shared && swift build && swift test
xcodebuild build -scheme Yentl -project apps/yentl/Yentl.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild build -scheme YentlMatchmaker \
  -project apps/yentl-matchmaker/YentlMatchmaker.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

The restored project files are a month old. Two likely failures: source files
added since June are on disk but not in the target's build phase, and SPM
dependencies are pinned to June versions and may need re-resolving. Fix what
breaks. If a target is unrecoverable, say so rather than papering over it.

**2. The owed hands-on expiry test.**
Phase 6 Slice 2 (match expiry, "ignored = rejected", asymmetric requeue) is
applied to the live DB and its pgTAP + Swift tests pass, but it has never been
exercised against a running app. The DB snapshot confirms `expire_stale_matches`,
`requeue_after_match` and `create_match` exist; what is unconfirmed is whether
the **pg_cron job actually fires**.

1. Verify the job exists and is active:
   `select jobname, schedule, active from cron.job where jobname='expire-stale-matches';`
   If it is missing, pg_cron likely is not enabled — that is a dashboard-only
   action, so **stop and ask**.
2. Clean slate: run `reset_matches.sql` then `reset_queue.sql` (in `supabase/dev/`).
3. Create a match: Debug matchmaker build → Review tab → pinned user has a
   candidate → **Match**. Note both names (A = pinned, B = candidate).
4. Accept on **one side only**: consumer app, 🐞 → switch to A → Matches →
   **Accept**. Leave B alone, so B "ignores".
5. Force expiry rather than waiting out the 5-minute DEBUG window:
   `update public.matches set expires_at = now() - interval '1 minute' where state='pending';`
   `select public.expire_stale_matches();`  (should return 1)
6. Verify three things: (a) consumer A's Matches shows **"This match expired."**;
   (b) queue order — A (accepted) at the **front**, B (ignored) at the **back**;
   (c) `select status, count(*) from matchmaking_queue group by status;` shows
   **no rows `matched`**.

Note step 5 forces the function by hand — that tests the *logic*, not the
*scheduler*. Confirming pg_cron fires on its own still requires observing a
match expire without manual intervention. Do not report the scheduler as
verified on the strength of the manual call.

**3. Phase 6 Slice 3** — per-user match history + matchmaker recent-matches
dashboard. Tag `v0.6.0` when verified (CI green *and* exercised in-app).

**4. Countdown polish** — make the consumer 24h countdown more clock-like and
add a matchmaker-side timer. Tracked alongside the expiry work.

**5. Continue** per `docs/implementation-plan.md`.

## Guardrails

- **The Supabase MCP writes to the live project. There is no staging DB.**
  Snapshot before any schema change (`~/Projects/yentl-backups/`, needs Docker
  running). Never `drop` a table, type or function without explicit user
  confirmation.
- **Never rewrite `main` history and never force-push.** The user reviews history
  actively. Small, single-purpose commits; end each message with the
  `Co-Authored-By:` line for the model doing the work.
- **Tag only verified states** — CI green *and* the behavior actually exercised.
  See `RELEASES.md`. Do not advance the `v0.x` line for unverified work.
- **Do not implement Phase 12 (profile approval) early**; it is intentionally
  mocked until then.
- **Apple Developer Program enrollment is required before Phase 8** (push/APNs).
  Remind the user well ahead of reaching it.
- Report honestly. If a test fails, show the output. If a step was skipped, say
  which. Do not describe generated-but-unrun code as working.

## Stop and ask

These cannot be done through any API — ask, do not attempt to automate:

- Enabling **pg_cron** and any other Supabase extension (Database → Extensions).
- Allowlisting redirect URLs `yentl://auth-callback` and
  `yentl-matchmaker://auth-callback` (Authentication → URL Configuration).
- Any credential the project does not yet hold — **Google OAuth** client ID and
  secret, **Stream Chat** key/secret (Phase 7), **OneSignal** app ID and REST key
  (Phase 8), Apple Developer enrollment.
- Anything destructive to live data.

## Project manager journal

Maintain `project-manager-log.md` throughout — this is a hard requirement, not a
nicety. It is written for a **non-technical reader**: someone who has never seen
the code should be able to follow how the project progressed.

- **One entry per work session**, headed `## Day N — YYYY-MM-DD` (add
  `→ YYYY-MM-DD` if the session crosses midnight). **No clock times** — the file
  has none, and a "day" here means one session, not one calendar day.
- Append to the current day's entry as milestones land; do not open a second
  entry for the same session.
- After each meaningful milestone record, in plain English: **what was
  accomplished**; **product or architectural decisions** made and *why*;
  **assumptions made because the documentation was silent** — this one matters
  most, it is where an autonomous build quietly guesses; and **what remains next**.
- Keep it concise. Avoid jargon, or explain it in a clause.
