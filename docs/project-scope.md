# Product Overview

Most dating apps rely entirely on algorithms.

Users swipe endlessly, compete for visibility, and hope the algorithm eventually produces a match.

Our platform takes a different approach.

The goal is not to maximize swipes, engagement, or time spent in the app.

The goal is to maximize successful real-world dates.

The platform combines user preferences, mutual interest, and human matchmaking.

Every user receives a genuine opportunity to be reviewed by a professional matchmaker rather than being permanently buried by an algorithm.

# Two-App Architecture

The platform consists of two separate applications.

## 1. Yentl

The public consumer app. Used by regular users.

Users can:

* Create a profile
* Upload photos
* Swipe on other users
* Like or pass profiles
* Chat after a match is created
* Confirm or reject proposed matches
* Schedule dates

## 2. Yentl Matchmaker

The internal app. Used exclusively by matchmakers.

Matchmakers can:

* Review profiles
* Approve new users
* Review users waiting in the matchmaking queue
* Analyze compatibility indicators
* Create matches
* Activate boosts
* Manage the matchmaking process

Both applications share the same backend and database.

# MVP Scope

* Heterosexual matching only at MVP. Same-sex and broader orientation support is deferred to a later release.
* Both applications target iOS at MVP. Android is a long-term enhancement.

# Core Matching Philosophy

Most dating apps operate like this:

User
→ Swipe
→ Algorithm
→ Match

This platform operates like this:

User
→ Swipe
→ Mutual Interest
→ Matchmaker Review
→ Official Match
→ 24-Hour Confirmation Window
→ Date

Human judgment is intentionally kept at the center of the matching process.

# Monetization

Yentl uses a **per-confirmed-date fee** model.

The platform is free to use until both users mutually confirm a match. When a date is confirmed by both sides, a fee is collected.

This aligns revenue directly with the outcome the platform exists to deliver — real dates — and avoids the pattern of paywalling features that do not produce results.

Payments are processed through Apple In-App Purchase. Apple's policies around real-world vs. digital services for date fees must be confirmed before launch, and may force a 30% revenue cut even on dates that take place offline.

Open questions to resolve before launch:

* Who pays the fee — one side, both, or split
* The fee amount
* How to discourage "confirm-then-ghost" behavior intended to game the system
* Refund or dispute policy when a confirmed date does not happen

# Recommended Tech Stack

| Layer              | Pick                           | Why                                                 |
| ------------------ | ------------------------------ | --------------------------------------------------- |
| Yentl              | Swift + SwiftUI                | Native iOS experience                               |
| Yentl Matchmaker   | Swift + SwiftUI                | Dedicated internal matchmaking application          |
| Backend            | Supabase                       | Flexible Postgres-based backend                     |
| Authentication     | Google Sign-In + Apple Sign-In | Fast onboarding and App Store compliant             |
| Chat               | Stream Chat                    | Production-ready messaging platform                 |
| Photos & Storage   | Supabase Storage               | Integrated and scalable                             |
| Profile Moderation | AI Screening + Human Approval  | Quality control before profiles go live             |
| Push Notifications | OneSignal                      | Notifications, reminders, and operational messaging |
| Payments           | Apple In-App Purchase (IAP)    | Native payment experience                           |
| Database           | PostgreSQL (via Supabase)      | Relational model ideal for matchmaking workflows    |

# Profile Approval Workflow

Every profile is reviewed before entering the matchmaking ecosystem.

Registration
↓
Photo Upload
↓
AI Screening
↓
Matchmaker Review
↓
Profile Approved
↓
Profile Goes Live

# Queue-Based Matching System

Every approved user enters the matchmaking queue.

The queue alternates between men and women.

Example:

Man #1
↓
Woman #1
↓
Man #2
↓
Woman #2
↓
Man #3
↓
Woman #3

The objective is ensuring that every user eventually reaches a matchmaker's review screen.

# Matchmakers Decision Panel

The Matchmakers Decision Panel is the operational heart of the platform.

The interface is intentionally designed to feel similar to Yentl.

Rather than working with spreadsheets, filters, and tables, matchmakers review profiles in a swipe-based environment.

# Decision Panel Layout

## Top Section (Pinned User)

The user currently being matched remains fixed at the top of the screen.

Displayed information:

* Avatar
* Age
* Location
* Attractiveness percentile
* Height percentile
* Income percentile
* Activity percentile
* Internal notes

This user remains fixed until either:

* A match is created
* A boost is activated

## Bottom Section (Candidate Viewer)

Potential matches appear one at a time.

For a male user, the candidate sequence begins with women who have already liked him.

For a female user, the candidate sequence begins with men who have already liked her.

Displayed information:

* Avatar
* Age
* Location
* Attractiveness percentile
* Height percentile
* Income percentile
* Activity percentile

Compatibility indicators may be displayed using visual bars or heatmap-style comparisons.

# Profile Inspection

When a matchmaker taps an avatar:

The full public profile opens exactly as it appears inside Yentl.

The matchmaker can review:

* Photos
* Bio
* Interests
* Prompts
* Public information

A back button returns the matchmaker to the Decision Panel.

# Hidden Matchmaker Data

The following information is only visible inside Yentl Matchmaker:

* Height
* Income
* Internal attractiveness rating
* Internal notes
* Activity metrics
* Match history
* Queue history
* Boost history

This information is never exposed to users.

The internal attractiveness rating is **matchmaker-assigned** during profile review, not algorithmic. Matchmakers rate each approved profile when it first reaches them, and the resulting percentile is used by other matchmakers in subsequent Decision Panel sessions. The rating inherits human judgment by design and must be calibrated across matchmakers to remain useful.

# Matchmaker Workflow

User Reaches Front Of Queue
↓
Matchmaker Reviews User
↓
Browse Candidate Profiles
↓
Open Profiles If Needed
↓
Compare Compatibility Indicators
↓
Create Match

or

Activate Boost

# Matchmaker Actions

## MATCH

Creates an official match between the pinned user and the currently displayed candidate.

Both users are notified and enter the confirmation stage.

## BOOST

Used when the matchmaker believes the user has insufficient opportunities available.

The boost temporarily increases profile visibility inside Yentl.

The objective is to generate additional likes and expand the candidate pool.

Once a sufficient number of additional likes is generated (threshold to be determined), the user returns to the front of the matchmaking queue for another review.

# Match Confirmation Workflow

Official Match Created
↓
Users Notified
↓
24-Hour Confirmation Window

If Both Accept
↓
Chat Opens
↓
Date Planning

If Either Rejects, or Does Not Respond Within 24 Hours
↓
The non-responding or rejecting user moves lower in the matchmaking queue.
↓
The other user keeps their high queue position and is returned to the front for another matchmaker review.

Ignoring a match is treated the same as rejecting it. This keeps the system simple and rewards users who show up for the people they have matched with.

# Long-Term Enhancements

* Identity verification
* AI-assisted compatibility scoring
* Advanced matchmaker analytics
* Performance dashboards for matchmakers
* Android versions of both applications

# Core Product Differentiator

The platform does not promise unlimited matches.

The platform promises that every user will receive genuine matchmaking attention.

Rather than relying exclusively on algorithms, human matchmakers actively participate in the matching process and are accountable for helping users reach real-world dates.

# Elevator Pitch

We are building a dating app where real matchmakers, not just an algorithm, decide who you match with.

On most dating apps, users swipe endlessly and let an algorithm do all the work. People rarely end up on real dates. We do it differently. Every user gets reviewed by a professional matchmaker who personally selects matches for them.

The product is two apps that share the same backend.

**Yentl** is what regular users see. It looks and feels like a normal dating app — create a profile, upload photos, swipe on others, and chat after a match. The difference is that the matches you receive have been hand-picked by a real matchmaker, not just generated by an algorithm.

**Yentl Matchmaker** is the private internal tool our matchmakers use. Regular users never see it. Matchmakers use it to review new sign-ups, look at users waiting in the matchmaking queue, and create matches between compatible people. The interface is designed to feel like a swipe-based dating app rather than a spreadsheet, so matchmaking is fast and human.

We make money only when matches turn into real dates: when both users confirm they want to meet, a small fee is collected.

In one line: real matchmakers, real attention, real dates.
