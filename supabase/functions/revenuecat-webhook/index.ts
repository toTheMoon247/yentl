// Phase 9 (Slice 1): revenuecat-webhook — keeps the payments ledger honest
// when money moves *outside* the app: refunds, chargebacks, refund reversals.
//
// RevenueCat POSTs a JSON body of the shape
//   { "api_version": "1.0", "event": { "type": "...", "app_user_id": "...",
//     "transaction_id": "<store txn id>", "product_id": "...", ... } }
// (verified against the current webhook docs, 2026-07-22). `transaction_id`
// is the store's transaction identifier — the same value the ledger stores as
// store_transaction_id, which is what makes the mapping trivial and
// idempotent.
//
// AUTHENTICATION: RevenueCat webhooks carry a dashboard-configured
// Authorization header value, sent verbatim with every request. This function
// requires that header to equal REVENUECAT_WEBHOOK_AUTH (constant-time
// comparison); anything else is 401 and touches nothing. This is the
// documented mechanism; RevenueCat also offers optional HMAC signing
// (X-RevenueCat-Webhook-Signature) which can be layered on later.
// `verify_jwt` is false in config.toml because RevenueCat is not a Supabase
// user — the shared secret above is the gate, not a Supabase JWT.
//
// Event handling (idempotent — a redelivered event repeats an UPDATE that is
// already in that state, or matches zero rows):
//   REFUND                → status='refunded' on the row with that
//                           transaction_id. (Chargebacks surface as refunds.)
//   CANCELLATION          → same. Our ledger only ever contains the date-fee
//                           consumable, and for a non-renewing purchase a
//                           CANCELLATION event means refund; subscription-style
//                           cancellations can't reference a ledger transaction
//                           id, so they match zero rows and are no-ops.
//   REFUND_REVERSED       → status='paid' again (the refund was overturned).
//   INITIAL_PURCHASE /
//   NON_RENEWING_PURCHASE → backfill amount/currency on an existing row (the
//                           webhook knows the customer's real price; the REST
//                           v2 lookup only knows USD gross). A purchase event
//                           for a transaction not in the ledger is ignored:
//                           rows are only ever CREATED by record-payment,
//                           which binds the purchase to a match — the webhook
//                           has no match context.
//   TEST / anything else  → acknowledged and ignored.
// Every authenticated, parseable request returns 200 — RevenueCat retries
// non-2xx responses, and retrying an event we chose to ignore helps nobody.
//
// Secrets: REVENUECAT_WEBHOOK_AUTH (function secret; via --env-file locally).
// It is never logged and never included in any response.

import { createClient } from "jsr:@supabase/supabase-js@2";

/** Small helper: JSON response with status. */
function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Constant-time string comparison (avoids timing side-channels on the token). */
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  // Compare same-length buffers; fold the length difference into the result.
  let diff = ab.length ^ bb.length;
  const len = Math.max(ab.length, bb.length);
  for (let i = 0; i < len; i++) {
    diff |= (ab[i % ab.length] ?? 0) ^ (bb[i % bb.length] ?? 0);
  }
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  try {
    // -----------------------------------------------------------------------
    // 1. Authenticate RevenueCat via the shared Authorization header value.
    // -----------------------------------------------------------------------
    const expectedAuth = Deno.env.get("REVENUECAT_WEBHOOK_AUTH");
    if (!expectedAuth) {
      // Fail CLOSED: with no configured secret, nothing is accepted.
      console.error("revenuecat-webhook: REVENUECAT_WEBHOOK_AUTH is not set");
      return json({ error: "server misconfigured" }, 500);
    }
    const gotAuth = req.headers.get("Authorization") ?? "";
    if (!timingSafeEqual(gotAuth, expectedAuth)) {
      return json({ error: "unauthorized" }, 401);
    }

    // -----------------------------------------------------------------------
    // 2. Parse the event.
    // -----------------------------------------------------------------------
    let event: Record<string, unknown>;
    try {
      const body = await req.json();
      event = body?.event ?? null;
    } catch {
      return json({ error: "invalid JSON body" }, 400);
    }
    if (!event || typeof event !== "object") {
      return json({ error: "missing event" }, 400);
    }

    const type = String(event.type ?? "").toUpperCase();
    const transactionId = String(event.transaction_id ?? "").trim();

    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!serviceRoleKey) {
      console.error("revenuecat-webhook: missing service-role key");
      return json({ error: "server misconfigured" }, 500);
    }
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceRoleKey, {
      auth: { persistSession: false },
    });

    // -----------------------------------------------------------------------
    // 3. Route by event type.
    // -----------------------------------------------------------------------
    if (type === "REFUND" || type === "CANCELLATION") {
      if (!transactionId) {
        // Nothing to map it to; acknowledge so RevenueCat stops retrying.
        console.warn(`revenuecat-webhook: ${type} without transaction_id`);
        return json({ ok: true, handled: false }, 200);
      }
      const { data: updated, error } = await admin
        .from("payments")
        .update({ status: "refunded" })
        .eq("store_transaction_id", transactionId)
        .select("id");
      if (error) {
        console.error("revenuecat-webhook: refund update failed:", error.message);
        return json({ error: "internal error" }, 500);
      }
      console.log(
        `revenuecat-webhook: ${type} -> refunded ${updated?.length ?? 0} row(s)`,
      );
      return json(
        { ok: true, handled: true, refunded: updated?.length ?? 0 },
        200,
      );
    }

    if (type === "REFUND_REVERSED") {
      if (!transactionId) {
        console.warn("revenuecat-webhook: REFUND_REVERSED without transaction_id");
        return json({ ok: true, handled: false }, 200);
      }
      const { data: updated, error } = await admin
        .from("payments")
        .update({ status: "paid" })
        .eq("store_transaction_id", transactionId)
        .select("id");
      if (error) {
        console.error(
          "revenuecat-webhook: refund-reversal update failed:",
          error.message,
        );
        return json({ error: "internal error" }, 500);
      }
      return json(
        { ok: true, handled: true, restored: updated?.length ?? 0 },
        200,
      );
    }

    if (type === "INITIAL_PURCHASE" || type === "NON_RENEWING_PURCHASE") {
      // Backfill the customer's real price/currency onto an existing row.
      // price_in_purchased_currency + currency are the customer-facing
      // amounts; price alone is USD. No row (record-payment not called yet,
      // or an unrelated purchase) → acknowledged no-op.
      if (transactionId) {
        const priceLocal = event.price_in_purchased_currency;
        const priceUSD = event.price;
        const currency = typeof event.currency === "string"
          ? event.currency
          : null;
        let amountCents: number | null = null;
        let amountCurrency: string | null = null;
        if (typeof priceLocal === "number" && currency) {
          amountCents = Math.round(priceLocal * 100);
          amountCurrency = currency;
        } else if (typeof priceUSD === "number") {
          amountCents = Math.round(priceUSD * 100);
          amountCurrency = "USD";
        }
        if (amountCents !== null) {
          const { error } = await admin
            .from("payments")
            .update({ amount_cents: amountCents, currency: amountCurrency })
            .eq("store_transaction_id", transactionId);
          if (error) {
            console.error(
              "revenuecat-webhook: amount backfill failed:",
              error.message,
            );
            // Non-fatal: the ledger's paid/refunded truth is unaffected.
          }
        }
      }
      return json({ ok: true, handled: true }, 200);
    }

    // TEST and every other event type: acknowledged, deliberately ignored.
    return json({ ok: true, handled: false }, 200);
  } catch (err) {
    console.error(
      "revenuecat-webhook: unexpected failure:",
      err instanceof Error ? err.message : String(err),
    );
    return json({ error: "internal error" }, 500);
  }
});
