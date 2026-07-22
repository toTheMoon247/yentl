// Phase 9 (Slice 1): record-payment — writes a verified 'paid' row into the
// payments ledger for (caller, match).
//
// Contract: POST { "match_id": "<uuid>", "store_transaction_id": "<store txn>" }
// with the caller's Supabase JWT in Authorization. The function
//   1. verifies the JWT (auth.getUser round-trip, exactly like stream-token),
//   2. loads the match and refuses unless the caller is a participant AND the
//      match state is 'confirmed' (the fee exists only for confirmed dates),
//   3. INDEPENDENTLY re-verifies the purchase against RevenueCat's REST API
//      v2 — the client's "I paid" claim is never trusted (see SECURITY below),
//   4. inserts the 'paid' payments row, idempotently on store_transaction_id.
//
// SECURITY — the property that matters: a payments row is written only when
// RevenueCat's *server-side* API, queried with our secret key for the
// *caller's* app-user-id (their Supabase user id, taken from the verified JWT
// and never from the body), reports a matching, non-refunded purchase. A
// forged or replayed client call can therefore at worst re-record a purchase
// RevenueCat actually validated with Apple — and the UNIQUE key on
// store_transaction_id makes even that a no-op that returns the existing row.
//
// RevenueCat verification (REST API v2, verified against the current docs
// 2026-07-22):
//   GET {REVENUECAT_API_BASE_URL}/projects/{REVENUECAT_PROJECT_ID}
//       /customers/{app_user_id}/purchases
//   with header  Authorization: Bearer {REVENUECAT_SECRET_KEY}
// (v2 requires the Bearer prefix; v1 accepted a bare key). Each returned
// purchase carries `store_purchase_identifier` — for the App Store, the
// StoreKit transaction id — plus `status` ('refunded' when revoked),
// `product_id` (RevenueCat's internal product id) and `customer_id` (the app
// user id). In API v2 the customer id IS the app-user-id, which the app sets
// to the Supabase user id, so the lookup is keyed to the caller's verified
// identity end to end. Pagination is followed via `next_page` (bounded).
//
// `verify_jwt` is false in config.toml for the same reasons documented in
// stream-token: the function authenticates callers itself via auth.getUser(),
// which is stricter than the gateway check and survives key-scheme changes.
//
// Secrets/env: REVENUECAT_SECRET_KEY (function secret; via --env-file
// locally), REVENUECAT_PROJECT_ID (RevenueCat project id — config, not a
// secret), REVENUECAT_API_BASE_URL (override so local tests hit a mock; same
// pattern as STREAM_API_BASE_URL in stream-channel), REVENUECAT_PRODUCT_ID
// (optional: when set, the purchase must be of this RevenueCat product id).

import { createClient } from "jsr:@supabase/supabase-js@2";

const DEFAULT_REVENUECAT_API_BASE_URL = "https://api.revenuecat.com/v2";
// Safety bound on pagination while searching the customer's purchases.
const MAX_PURCHASE_PAGES = 10;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Small helper: JSON response with status. */
function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** The subset of a ledger row the client gets back. Never the RevenueCat ids. */
function publicRow(row: Record<string, unknown>): Record<string, unknown> {
  return {
    id: row.id,
    match_id: row.match_id,
    user_id: row.user_id,
    product_id: row.product_id,
    store_transaction_id: row.store_transaction_id,
    status: row.status,
    created_at: row.created_at,
  };
}

interface RevenueCatPurchase {
  object?: string;
  id?: string;
  customer_id?: string;
  product_id?: string;
  status?: string;
  store_purchase_identifier?: string | number;
  revenue_in_usd?: { currency?: string; gross?: number };
}

/**
 * Search the caller's RevenueCat purchases for one whose
 * store_purchase_identifier equals storeTransactionId. Returns the purchase,
 * "not_found", or "customer_unknown" (RevenueCat 404 — the app user has no
 * customer record at all).
 */
async function findPurchase(
  baseURL: string,
  projectId: string,
  secretKey: string,
  appUserId: string,
  storeTransactionId: string,
): Promise<RevenueCatPurchase | "not_found" | "customer_unknown"> {
  let url: string | null =
    `${baseURL}/projects/${encodeURIComponent(projectId)}` +
    `/customers/${encodeURIComponent(appUserId)}/purchases`;

  for (let page = 0; url && page < MAX_PURCHASE_PAGES; page++) {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${secretKey}` },
    });
    if (res.status === 404) return "customer_unknown";
    if (!res.ok) {
      throw new Error(
        `RevenueCat purchases lookup failed (${res.status}): ` +
          (await res.text()).slice(0, 300),
      );
    }
    const body = await res.json();
    const items: RevenueCatPurchase[] = Array.isArray(body?.items)
      ? body.items
      : [];
    const hit = items.find(
      (p) => String(p.store_purchase_identifier ?? "") === storeTransactionId,
    );
    if (hit) return hit;

    // next_page is a path like /v2/projects/.../purchases?starting_after=…;
    // resolve it against the base URL's origin so the mock override works too.
    url = typeof body?.next_page === "string" && body.next_page.length > 0
      ? new URL(body.next_page, baseURL).toString()
      : null;
  }
  return "not_found";
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  try {
    // -----------------------------------------------------------------------
    // 1. Authenticate the caller (identical to stream-token).
    // -----------------------------------------------------------------------
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return json({ error: "missing authorization" }, 401);
    }
    const supabaseJWT = authHeader.slice("Bearer ".length);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
    );
    const { data, error } = await supabase.auth.getUser(supabaseJWT);
    if (error || !data?.user) {
      return json({ error: "invalid or expired session" }, 401);
    }
    // The ONLY source of the app-user-id used against RevenueCat.
    const callerId = data.user.id.toLowerCase();

    // -----------------------------------------------------------------------
    // 2. Parse and validate the request.
    // -----------------------------------------------------------------------
    let matchId: string;
    let storeTransactionId: string;
    try {
      const body = await req.json();
      matchId = String(body?.match_id ?? "").toLowerCase();
      storeTransactionId = String(body?.store_transaction_id ?? "").trim();
    } catch {
      return json({ error: "invalid JSON body" }, 400);
    }
    if (!UUID_RE.test(matchId)) {
      return json({ error: "match_id must be a UUID" }, 400);
    }
    if (
      storeTransactionId.length === 0 || storeTransactionId.length > 255
    ) {
      return json({ error: "store_transaction_id is required" }, 400);
    }

    // -----------------------------------------------------------------------
    // 3. Load the match and authorize (service-role read, like stream-channel:
    //    the checks here are the single source of truth regardless of RLS).
    // -----------------------------------------------------------------------
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const rcSecret = Deno.env.get("REVENUECAT_SECRET_KEY");
    const rcProjectId = Deno.env.get("REVENUECAT_PROJECT_ID");
    if (!serviceRoleKey || !rcSecret || !rcProjectId) {
      console.error(
        "record-payment: missing service-role key, REVENUECAT_SECRET_KEY or REVENUECAT_PROJECT_ID",
      );
      return json({ error: "server misconfigured" }, 500);
    }
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceRoleKey, {
      auth: { persistSession: false },
    });

    const { data: match, error: matchErr } = await admin
      .from("matches")
      .select("id, user_a, user_b, state")
      .eq("id", matchId)
      .maybeSingle();
    if (matchErr) {
      console.error("record-payment: match lookup failed:", matchErr.message);
      return json({ error: "internal error" }, 500);
    }
    if (!match) {
      return json({ error: "match not found" }, 404);
    }
    const userA = String(match.user_a).toLowerCase();
    const userB = String(match.user_b).toLowerCase();
    if (callerId !== userA && callerId !== userB) {
      return json({ error: "not a participant of this match" }, 403);
    }
    // The fee is charged for a confirmed date; there is nothing to pay for on
    // a pending/rejected/expired match.
    if (match.state !== "confirmed") {
      return json({ error: "match is not confirmed" }, 409);
    }

    // -----------------------------------------------------------------------
    // 4. Idempotency: if this store transaction is already in the ledger,
    //    return the existing row (same caller+match) or refuse (anything else
    //    — a transaction can pay for exactly one user's side of one match).
    // -----------------------------------------------------------------------
    const { data: existing, error: existingErr } = await admin
      .from("payments")
      .select("*")
      .eq("store_transaction_id", storeTransactionId)
      .maybeSingle();
    if (existingErr) {
      console.error(
        "record-payment: ledger lookup failed:",
        existingErr.message,
      );
      return json({ error: "internal error" }, 500);
    }
    if (existing) {
      if (
        String(existing.user_id).toLowerCase() === callerId &&
        String(existing.match_id).toLowerCase() === matchId &&
        existing.status === "paid"
      ) {
        const { data: paid } = await admin.rpc("is_match_paid", {
          match: matchId,
        });
        return json(
          {
            payment: publicRow(existing),
            match_paid: paid === true,
            already_recorded: true,
          },
          200,
        );
      }
      // Refunded, or recorded for a different user/match: not reusable.
      return json(
        { error: "transaction already recorded and not reusable" },
        409,
      );
    }

    // -----------------------------------------------------------------------
    // 5. Verify with RevenueCat. Only a purchase RevenueCat confirms for THIS
    //    app-user-id, matching the submitted store transaction id and not
    //    refunded, may enter the ledger.
    // -----------------------------------------------------------------------
    const baseURL = (Deno.env.get("REVENUECAT_API_BASE_URL") ??
      DEFAULT_REVENUECAT_API_BASE_URL).replace(/\/+$/, "");

    let purchase: RevenueCatPurchase | "not_found" | "customer_unknown";
    try {
      purchase = await findPurchase(
        baseURL,
        rcProjectId,
        rcSecret,
        callerId,
        storeTransactionId,
      );
    } catch (err) {
      console.error(
        "record-payment:",
        err instanceof Error ? err.message : String(err),
      );
      return json({ error: "payment backend unavailable" }, 502);
    }
    if (purchase === "customer_unknown" || purchase === "not_found") {
      // 402 Payment Required: RevenueCat has no such purchase for this user.
      return json({ error: "no matching purchase found" }, 402);
    }
    if (purchase.status === "refunded") {
      return json({ error: "purchase was refunded" }, 409);
    }
    const expectedProduct = Deno.env.get("REVENUECAT_PRODUCT_ID");
    if (expectedProduct && purchase.product_id !== expectedProduct) {
      return json({ error: "purchase is not the date fee product" }, 402);
    }

    // -----------------------------------------------------------------------
    // 6. Record it. The UNIQUE key on store_transaction_id resolves races: a
    //    concurrent duplicate insert loses and we return the winner's row.
    // -----------------------------------------------------------------------
    // v2 reports USD gross revenue; the webhook's purchase events later
    // overwrite with the customer's actual price/currency when they arrive.
    const gross = purchase.revenue_in_usd?.gross;
    const amountCents = typeof gross === "number"
      ? Math.round(gross * 100)
      : null;

    const { data: inserted, error: insertErr } = await admin
      .from("payments")
      .insert({
        user_id: callerId,
        match_id: matchId,
        product_id: purchase.product_id ?? null,
        store_transaction_id: storeTransactionId,
        revenuecat_customer_id: purchase.customer_id ?? null,
        status: "paid",
        amount_cents: amountCents,
        currency: amountCents !== null ? "USD" : null,
      })
      .select("*")
      .single();

    let row = inserted;
    if (insertErr) {
      if (insertErr.code === "23505") {
        // Lost a race with an identical request: return the existing row.
        const { data: winner } = await admin
          .from("payments")
          .select("*")
          .eq("store_transaction_id", storeTransactionId)
          .maybeSingle();
        if (
          winner &&
          String(winner.user_id).toLowerCase() === callerId &&
          String(winner.match_id).toLowerCase() === matchId
        ) {
          row = winner;
        } else {
          return json(
            { error: "transaction already recorded and not reusable" },
            409,
          );
        }
      } else {
        console.error("record-payment: insert failed:", insertErr.message);
        return json({ error: "internal error" }, 500);
      }
    }

    const { data: paid, error: paidErr } = await admin.rpc("is_match_paid", {
      match: matchId,
    });
    if (paidErr) {
      console.error(
        "record-payment: is_match_paid failed:",
        paidErr.message,
      );
    }
    return json(
      { payment: publicRow(row!), match_paid: paid === true },
      200,
    );
  } catch (err) {
    console.error(
      "record-payment: unexpected failure:",
      err instanceof Error ? err.message : String(err),
    );
    return json({ error: "internal error" }, 500);
  }
});
