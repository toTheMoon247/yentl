# Monetization model — "Unlock your match"

Decision record for how Yentl charges. Settled 2026-07-23. Supersedes the
earlier "per-confirmed-date fee" framing.

## The model (what ships at launch)

Money is tied to **unlocking the conversation with a mutually-accepted match** —
NOT to a real-world date.

The match lifecycle:

```
Matchmaker proposes a match            → state: PENDING
  each person ACCEPTS or REJECTS (FREE; 24h; ignore = reject)
Both accepted                          → state: CONFIRMED
  each person pays their own fee to unlock ("Unlock your match")
Both paid                              → chat opens
```

Key properties:
- **Accepting is free and happens before any charge.** A person can only reach
  the pay screen *after the other has already accepted* (the match is CONFIRMED).
  So if the other rejects or lets it expire, you are never shown a payment and
  never charged.
- **Each participant pays their own fee** (both have skin in the game → filters
  for mutual seriousness).
- The chat opens only when **both** have paid.

### Product
- **Product ID:** `match_unlock` (App Store Connect + RevenueCat). *Permanent —
  chosen deliberately over the old `date_fee`.*
- **Type:** Consumable (paid per match, repeatedly).
- **Display name (what users see):** "Unlock your match".
- **Price:** $4.99 (matches the dev Test Store price; final call at launch).

## Why unlock-the-chat, not charge-for-a-real-date

1. **Enforceability.** The chat is the only chokepoint. If we charged only when a
   real date is "confirmed," people would arrange the date inside a free chat and
   never pay. Revenue collapses.
2. **App Store risk.** Apple accepts IAP that unlocks *digital* features (a chat).
   It is far warier of IAP for *real-world services* (an actual date). "Unlock
   your match" is the safer framing — this also lowers the risk on the standing
   [[apple-iap-date-fee-assumption]] (proceeding without written Apple sign-off).

## Deferred — build after launch (do NOT lose these)

These are known fairness gaps. At launch we accept them and lean on manual
handling; each is a real follow-up.

1. **Queue priority for payers.** Today, a paid user whose match fizzled goes to
   the *back* of the re-queue — paid, no date, demoted. The fix: put paid-and-
   fizzled users at the *front* of the re-queue (reward commitment; better
   service for payers). **This is the main fairness lever.**
2. **"They flaked → next one's on us" credit.** If the *other* person ghosts or
   unmatches shortly after you paid, credit your next unlock. Caps the payer's
   downside without letting people chat-and-dodge for free.
3. **One-sided payment.** Both accepted, David pays, Jane (who accepted) never
   pays → David is charged, chat stays locked. **Apple does not let the developer
   initiate refunds** (the user must request from Apple), so the clean remedy is
   an **in-app credit**, not a refund. Rare (she already accepted).

## Launch stance

Ship the simplest fair version: free accept → pay-to-unlock after both accept,
honestly framed as buying *the conversation / the chance*, not a guaranteed date.
Handle the rare edge cases (one-sided payment) with **manual** App Store refunds
until items 1–3 are built. Reconsider a credit system or queue-priority once
there is real usage data.
