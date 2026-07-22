// Phase 8 (Slice 2): notify — sends lifecycle push notifications via OneSignal.
//
// The consumer app registers each signed-in user with OneSignal under
// external_id = the Supabase auth user UUID, lowercased (OneSignal.login in
// ContentView). That makes every user's devices addressable server-side by the
// same id the schema keys on, so this function only needs a match id and an
// event name to reach both participants.
//
// Contract: POST { "match_id": "<uuid>", "event": "match_created" |
// "match_confirmed" } with the caller's Supabase JWT in Authorization.
//   1. verifies the JWT (auth.getUser round-trip, exactly like stream-token),
//   2. loads the match with a service-role read and authorizes: the caller
//      must be a PARTICIPANT of the match or STAFF (matchmaker/admin role in
//      public.users) — match_created is fired by the matchmaker app after
//      create_match, match_confirmed by the participant whose accept
//      confirmed the match. Everyone else → 403.
//   3. gates the event on the match's actual state: match_created requires
//      'pending', match_confirmed requires 'confirmed'; mismatch → 409. This
//      is what lets the consumer app fire match_confirmed after EVERY accept:
//      the first accept leaves the match pending (409, no push), the second
//      flips it to confirmed and the push goes out exactly then. It also stops
//      anyone re-pushing "new match" for long-resolved matches.
//   4. pushes to BOTH participants (never the matchmaker) through OneSignal's
//      REST API, targeting include_aliases.external_id.
//
// Content is deliberately NON-ATTRIBUTING, matching the app's tone: nothing
// sent here ever says who accepted or rejected whom. (That is also why
// match_rejected has no event at all — see the note at the bottom.)
//
// Idempotency: repeat calls do not crash, and each (match, event) pair carries
// a deterministic idempotency_key derived from the match id, so OneSignal
// itself deduplicates re-sends within its 30-day window. Best-effort beyond
// that: a push that reaches no subscribed device is a 200 with sent=false,
// never an error — clients treat the whole call as fire-and-forget.
//
// SECURITY: caller identity comes ONLY from the verified Supabase JWT — never
// the body. `verify_jwt` is false in config.toml for the reasons documented in
// stream-token (the gateway check would accept the anon key; in-function
// auth.getUser is stricter and survives asymmetric signing keys).
//
// Secrets: ONESIGNAL_REST_API_KEY is a Supabase function secret (the modern
// "App API key" scheme: `Authorization: Key <key>`); it is never logged and
// never included in any response. The App ID is public — it ships in the iOS
// app (Environment.swift) — and may be overridden with ONESIGNAL_APP_ID.
// ONESIGNAL_API_BASE_URL exists so local tests can point at a mock instead of
// the real OneSignal backend (same pattern as stream-channel's
// STREAM_API_BASE_URL); it defaults to OneSignal's API edge.

import { createClient } from "jsr:@supabase/supabase-js@2";

// Same public App ID the consumer app embeds (shared/.../Environment.swift).
const DEFAULT_ONESIGNAL_APP_ID = "d0a0569f-87cd-418b-801b-104795255ce2";
const DEFAULT_ONESIGNAL_API_BASE_URL = "https://api.onesignal.com";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** The two lifecycle events this slice sends, with their (non-attributing)
 * push copy and the match state each is valid in. */
const EVENTS = {
  match_created: {
    requiredState: "pending",
    heading: "You have a new match!",
    content: "Open Yentl to see who it is.",
  },
  match_confirmed: {
    requiredState: "confirmed",
    heading: "It's a match! 🎉",
    content: "You can start chatting now.",
  },
} as const;
type EventName = keyof typeof EVENTS;

/** Small helper: JSON response with status. */
function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Deterministic UUIDv5 (SHA-1, fixed namespace) so a given (match, event)
 * always produces the same OneSignal idempotency_key: OneSignal then dedupes
 * accidental re-sends for 30 days without this function needing state. */
async function idempotencyKey(matchId: string, event: string): Promise<string> {
  // Random-but-fixed namespace, generated once for this function.
  const namespace = "3b8f2b74-9c1e-4f6a-9d27-5f04c1e5a8d1";
  const nsBytes = namespace.replace(/-/g, "").match(/.{2}/g)!
    .map((h) => parseInt(h, 16));
  const nameBytes = new TextEncoder().encode(`${matchId}:${event}`);
  const input = new Uint8Array([...nsBytes, ...nameBytes]);
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-1", input));
  const b = hash.slice(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50; // version 5
  b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
  const hex = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${
    hex.slice(16, 20)
  }-${hex.slice(20)}`;
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
    const callerId = data.user.id.toLowerCase();

    // -----------------------------------------------------------------------
    // 2. Parse and validate the request.
    // -----------------------------------------------------------------------
    let matchId: string;
    let event: EventName;
    try {
      const body = await req.json();
      matchId = String(body?.match_id ?? "").toLowerCase();
      event = String(body?.event ?? "") as EventName;
    } catch {
      return json({ error: "invalid JSON body" }, 400);
    }
    if (!UUID_RE.test(matchId)) {
      return json({ error: "match_id must be a UUID" }, 400);
    }
    if (!(event in EVENTS)) {
      return json({ error: "event must be match_created or match_confirmed" }, 400);
    }
    const spec = EVENTS[event];

    // -----------------------------------------------------------------------
    // 3. Load the match (service-role read) and authorize: participant OR
    //    staff. Unlike stream-channel, staff MUST pass here — match_created is
    //    fired by the matchmaker app, whose user is never a participant.
    // -----------------------------------------------------------------------
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const restKey = Deno.env.get("ONESIGNAL_REST_API_KEY");
    if (!serviceRoleKey || !restKey) {
      console.error("notify: missing service-role key or ONESIGNAL_REST_API_KEY");
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
      console.error("notify: match lookup failed:", matchErr.message);
      return json({ error: "internal error" }, 500);
    }
    if (!match) {
      return json({ error: "match not found" }, 404);
    }

    const userA = String(match.user_a).toLowerCase();
    const userB = String(match.user_b).toLowerCase();

    if (callerId !== userA && callerId !== userB) {
      // Not a participant — allowed only for staff. Same role source as the
      // SQL is_matchmaker_or_admin() helper, read via service role.
      const { data: caller, error: roleErr } = await admin
        .from("users")
        .select("role")
        .eq("id", callerId)
        .maybeSingle();
      if (roleErr) {
        console.error("notify: role lookup failed:", roleErr.message);
        return json({ error: "internal error" }, 500);
      }
      if (caller?.role !== "matchmaker" && caller?.role !== "admin") {
        return json({ error: "not authorized for this match" }, 403);
      }
    }

    // -----------------------------------------------------------------------
    // 4. Gate the event on the match's actual state (see header). This is the
    //    check that makes client-side firing safe and repeat calls harmless.
    // -----------------------------------------------------------------------
    if (match.state !== spec.requiredState) {
      return json(
        { error: `match is not ${spec.requiredState}`, state: match.state },
        409,
      );
    }

    // -----------------------------------------------------------------------
    // 5. Send the push to BOTH participants via OneSignal's REST API.
    //    Current scheme (docs, 2026): POST {base}/notifications?c=push with
    //    `Authorization: Key <App API key>`; recipients go in
    //    include_aliases.external_id + target_channel "push".
    // -----------------------------------------------------------------------
    const appId = Deno.env.get("ONESIGNAL_APP_ID") ?? DEFAULT_ONESIGNAL_APP_ID;
    const baseURL = (Deno.env.get("ONESIGNAL_API_BASE_URL") ??
      DEFAULT_ONESIGNAL_API_BASE_URL).replace(/\/+$/, "");

    const pushRes = await fetch(`${baseURL}/notifications?c=push`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Key ${restKey}`,
      },
      body: JSON.stringify({
        app_id: appId,
        include_aliases: { external_id: [userA, userB] },
        target_channel: "push",
        headings: { en: spec.heading },
        contents: { en: spec.content },
        // Deep-link payload for the app's future push-tap routing (Phase 8
        // follow-up): open the Matches tab / this match's detail.
        data: { route: "match", match_id: matchId, event },
        idempotency_key: await idempotencyKey(matchId, event),
      }),
    });

    if (!pushRes.ok) {
      console.error(
        `notify: OneSignal rejected the notification (${pushRes.status}):`,
        (await pushRes.text()).slice(0, 500),
      );
      return json({ error: "push backend rejected notification" }, 502);
    }

    // HTTP 200 has two shapes: a real id (created), or an empty/absent id
    // meaning no notification was created — e.g. neither participant has a
    // subscribed device yet. The latter is normal (simulators can't receive
    // APNs pushes) and is NOT an error for a best-effort notification.
    const result = await pushRes.json().catch(() => ({}));
    const notificationId = typeof result?.id === "string" ? result.id : "";
    if (!notificationId) {
      console.warn("notify: no notification created (no subscribed recipients?)");
    }
    return json(
      { sent: notificationId !== "", notification_id: notificationId || null },
      200,
    );
  } catch (err) {
    // Log the message only — never the request headers or any env value.
    console.error(
      "notify: unexpected failure:",
      err instanceof Error ? err.message : String(err),
    );
    return json({ error: "internal error" }, 500);
  }
});

// Phase 8 (later) — deliberately NOT implemented in this slice:
//
// - match_rejected / match_expired pushes. Rejection is sensitive: the app
//   never tells someone they were the one rejected (the UI says "This match
//   wasn't accepted by both people"), so a rejection push must either stay
//   equally non-attributing or not exist at all. That product decision is
//   left open; no event is defined here so it cannot be sent accidentally.
//
// - "expiring soon" (~4h left) reminder. No client is attached at that
//   moment, so it needs a scheduler calling this function (or OneSignal
//   directly): pg_cron + pg_net on the project (pg_net enablement is a
//   dashboard action) or an external cron. Follow-up slice.
//
// - New-message pushes. Those are Stream-native (hybrid decision from the
//   Phase 7/8 planning): Stream's own push integration handles them, not
//   this function.
//
// - OneSignal Identity Verification (signed identity tokens before
//   OneSignal.login). Needs a token-signing endpoint first; until the
//   dashboard toggle is enabled, external_id login is unsigned.
