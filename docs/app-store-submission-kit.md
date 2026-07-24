# App Store Submission Kit — Yentl (consumer app `com.yentl.app`)

Everything needed to fill out the App Store Connect record, derived from how the
app **actually** works as of v0.12.0 (2026-07-23). Two audiences: the **App
Privacy** questionnaire and the **listing**. Items you still have to supply are
marked **[YOU]**.

> Scope: this kit is for the **public consumer app** (`com.yentl.app`). The
> internal matchmaker app (`com.yentl.matchmaker`) is staff-only and, if
> distributed at all, goes via TestFlight/internal — not the public App Store.

---

## 0. Launch progress (live status — updated 2026-07-24)

**Done:**
- ✅ **App record** in App Store Connect (`com.yentl.app`, Apple ID `6794065289`).
- ✅ **IAP `match_unlock`** (Consumable, "Unlock your match", $4.99) — availability, pricing, localization set. *Not* "Add for Review" yet (submits with the first app version).
- ✅ **RevenueCat production wired** — App Store app `app59442a6809`; product `match_unlock` (`prod99110c4a83`) in the **`default`** offering (`ofrng2fa65a0d5e`), package `pkge67e1553d60`, alongside the dev Test Store `date_fee`. Prod key `appl_…` in `Environment.swift` (`.prod`).
- ✅ **Monetization reframed** to "Unlock your match" (see `docs/monetization-model.md`).
- ✅ **Legal pages hosted** — GitHub Pages live; **Privacy Policy URL set** in App Store Connect
  (`https://tothemoon247.github.io/yentl/legal/privacy.html`). Contact email → a real inbox.
- ✅ **App Privacy published** (all 10 data types: App Functionality / Linked: Yes / Tracking: No).
- ✅ **Age Rating: 18+** — content calculated 16+, legitimately overridden to 18+ via the EULA age requirement.
- ✅ **Content Rights** declared (no third-party content) · **Export compliance** (`ITSAppUsesNonExemptEncryption=false` in Info.plist).
- ✅ **Screenshots** captured (`~/Documents/Yentl App Store Screenshots`), incl. the pay-gate shot for the IAP review image.

**Waiting / next up:**
1. ✅ **Payments fully wired** — RevenueCat "Yentl App Store" app now has the **In-App Purchase key** (`.p8` `SubscriptionKey_9MF9SK5BKZ`, Key ID `9MF9SK5BKZ`, Issuer `c4231410-…`) → "Valid credentials". (The In-App Purchase key, not the legacy App-Specific Shared Secret, is what StoreKit 2 needs.) *Optional later:* App Store Connect API key (auto-import products/prices — not needed since `match_unlock` was made manually) + Apple Server-to-Server notification URL.
2. ✅ **Digital Services Act — avoided for launch** by making the **27 EU countries unavailable** (Pricing and Availability → Availability). No trader declaration / no public personal details. Reversible: re-add the EU + complete the trader form later (needs a business entity or accepting public personal contact details). App price set to **Free** (monetized via the `match_unlock` IAP).
3. ⬜ **Version page** — description, keywords, promo text, screenshots (all drafted/captured: §3 + the screenshots folder + `app-icon-1024.png`).
4. ⬜ **Build → TestFlight → submit** — version/build number → Archive → upload → test on device → submit app + IAP together (review notes §4 + demo account).
5. ⬜ **Legal review** of Terms/Privacy + fill placeholders (entity, address, governing law) before public launch.

---

## 1. App Privacy ("nutrition labels")

### Tracking
**Does this app track users?** → **No.** There are no advertising or analytics
SDKs, no IDFA/AppTrackingTransparency, and no data shared with data brokers or
used to track across other companies' apps/sites. So **no ATT prompt** is needed
and "Used for Tracking" is **No** for every data type below.

### Data collected — all **Linked to the user's identity**, all purpose **App Functionality** (none for tracking, advertising, or third-party analytics)

| Apple data type | What it is in Yentl | Notes |
|---|---|---|
| **Contact Info → Name** | Display name on the profile | |
| **Contact Info → Email Address** | From Apple / Google sign-in | Account auth only |
| **User Content → Photos** | Profile photos | Also processed for automated screening (see §4) |
| **User Content → Other** | Bio, prompts, interests, the city they enter | The location is **user-typed text**, not device location |
| **User Content → Customer Support / Other** | Reports a user files about others | Safety/moderation |
| **User Content → Emails or Text Messages** | In-app chat messages (via Stream) | Between matched users |
| **Identifiers → User ID** | Supabase user id (also used as the id in Stream / RevenueCat / OneSignal) | |
| **Financial Info → Other Financial Info** | **Annual income** — a *required* profile field, used for matchmaking | Hidden matchmaker field (owner + staff only); NOT card/payment data |
| **Purchases → Purchase History** | The match-unlock fee | We store paid/refunded status, **not** card data |
| **Usage Data → Product Interaction** | Likes/passes and matches | Core functionality, not analytics |
| **Other Data → Date of birth** | For 18+ verification and matching | See the Sensitive-Info judgment call below |

### Data explicitly **NOT** collected
Precise/GPS location · Contacts · Health & Fitness · **Payment/card info**
(Apple/RevenueCat process payments; the developer never receives card details —
note: annual **income** IS collected, declared under Financial Info → Other
Financial Info above) · Browsing/Search history · Audio · Diagnostics/Crash data
*(none today — when a crash reporter like Sentry is added, declare **Diagnostics
→ Crash Data**)*.

### Two judgment calls to settle with the lawyer **[YOU]**
1. **Sensitive Info (sexual orientation).** Apple's "Sensitive Info" category
   includes sexual orientation. Yentl is heterosexual-only at MVP and does not
   ask orientation directly, but a dating profile implies it. Many dating apps
   declare it to be safe. Decide whether to declare **Sensitive Info**.
2. **Coarse Location.** The city is *user-entered text*, not device-derived, so
   it's classified above as User Content. If your reviewer treats a self-entered
   city as **Coarse Location**, declare it there instead (Linked, App
   Functionality, not tracking). No `NSLocation…UsageDescription` is needed
   either way — the app never calls CoreLocation.

### Third parties / sub-processors (for the Privacy Policy, already listed there)
Supabase (hosting/DB/storage) · Stream (chat) · OneSignal (push) · RevenueCat +
Apple (payments) · OpenAI (automated profile screening — photos + text). All
process data for app functionality under contract; none for advertising/tracking.

---

## 2. Age rating

**17+.** A dating app with the ability to meet strangers and exchange messages
maps to Apple's **17+** (the highest standard tier). Relevant questionnaire
answers: *Mature/Suggestive Themes → Frequent/Intense; Unrestricted Web Access →
No; Medical/Gambling/Contests → None.* The app **additionally enforces 18+**
in-app via the onboarding age confirmation.

---

## 3. Listing copy (draft — edit to taste)

- **App Name** (≤30): `Yentl` *(or `Yentl — Matchmaker Dating`, 25 chars, for search)*
- **Subtitle** (≤30): `Real matchmakers, real dates`
- **Promotional text** (≤170): `Skip the endless swiping. Yentl's professional matchmakers hand-pick your introductions — you unlock only the matches you both want.`
- **Keywords** (≤100, comma-separated, no spaces):
  `matchmaker,dating,matchmaking,singles,relationships,serious dating,introductions,love,meet,marriage`
- **Support URL**: `https://tothemoon247.github.io/yentl/support.html` (hosted support page, contact `the.yona.app@gmail.com`)
- **Marketing URL** (optional) **[YOU]**
- **Privacy Policy URL** **[YOU — REQUIRED]**: the ToS/Privacy from Slice 3 must be **publicly hosted** and linked here.

### Description (draft)
> **Dating, decided by people — not an algorithm.**
>
> Yentl is a different kind of dating app. Instead of leaving you to swipe
> through an endless feed, professional matchmakers review profiles and
> hand-pick who you're introduced to. Thoughtful, human, intentional.
>
> **How it works**
> • Build a profile — our matchmakers (and a safety screen) review it before it
>   goes live.
> • Get introduced to people chosen for you, not served by an algorithm.
> • When you've both accepted, each of you unlocks the match with a small fee —
>   and the conversation opens.
>
> **Why Yentl**
> • Real matchmakers making thoughtful introductions.
> • No pay-to-win subscriptions — you pay only to unlock a match you both want.
> • Safety first: every profile is screened, and you can report, block, or
>   delete your account anytime.
>
> For adults 18+. Meet thoughtfully.

---

## 4. App Review notes (App Review Information)

Give the reviewer what they need so the human-matchmaker + paid-unlock model
isn't mistaken for something it isn't:

- **Demo account [YOU]:** provide a reviewer login (a seed consumer account, or
  a fresh Apple/Google account) so review can see a completed profile and the
  matching flow without waiting on a real matchmaker.
- **Explain the model:** "Matches are curated by human matchmakers. To
  demonstrate the full flow without a live matchmaker, use the provided demo
  account, which already has a match ready."
- **On the fee (important):** state plainly that the in-app purchase
  (**"Unlock your match"**) unlocks the **in-app conversation** with a match —
  a digital unlock within the app, delivered through Apple IAP (not a fee for a
  real-world date or service). *(See docs/monetization-model.md; the review
  notes are where we frame this as a digital unlock.)*
- **Sign in with Apple** is implemented (native) alongside Google, per 4.8.

---

## 5. Remaining checklist to submit

- [ ] **[YOU]** Legal review of Terms/Privacy + fill placeholders (entity, address, governing law)
- [ ] **[YOU]** Host the privacy policy publicly and put the URL in the listing
- [ ] **[YOU]** Create the real **IAP product** in App Store Connect (dev uses RevenueCat's Test Store) + a sandbox purchase test
- [ ] **[YOU]** Provide a reviewer demo account + review notes (above)
- [ ] Screenshots for required device sizes (I can capture these from the simulator on request)
- [ ] App icon finalized in the asset catalog
- [ ] Fill the App Privacy questionnaire using §1
- [ ] Set age rating 17+ using §2
- [ ] Upload a build via TestFlight (Phase 13), smoke-test on device, then submit
