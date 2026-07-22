// Phase 7 (Slice 3): stream-channel — server-side Stream channel creation
// for a confirmed match.
//
// Until this function existed, the consumer app created the `match-<uuid>`
// channel client-side on first open. That worked only by luck: Stream's
// client API can add a *member who already exists in Stream*, but a matched
// partner who has never connected has no Stream user at all, so the channel
// could not reliably include both people. Only a server-side call (signed
// with the API secret) may UPSERT users — which is exactly why creation
// moves here.
//
// Contract: POST { "match_id": "<uuid>" } with the caller's Supabase JWT in
// Authorization. The function
//   1. verifies the JWT (auth.getUser round-trip, exactly like stream-token),
//   2. loads the match and refuses unless the caller is a participant AND
//      the match state is 'confirmed',
//   3. upserts BOTH participants as Stream users (id = lowercased Supabase
//      UUID, name = profile display_name),
//   4. creates-or-ensures the channel `messaging:match-<uuid>` with both
//      participants as members.
// Every step is idempotent: user upsert is an upsert, and Stream's
// `channels/{type}/{id}/query` endpoint returns the existing channel rather
// than failing, so the client may call this repeatedly (on observing a
// confirmed match, and again before opening the chat).
//
// SECURITY: the caller's identity comes ONLY from the verified Supabase JWT
// — never from the body. The participant + confirmed checks run in this
// function against a service-role read of the match row, so they hold
// regardless of RLS configuration. A non-participant gets 403 even if they
// are staff; a pending/rejected/expired match gets 409. `verify_jwt` is
// false in config.toml for the same reasons documented in stream-token.
//
// Secrets: STREAM_API_SECRET (function secret; via --env-file locally). The
// API key is public (it ships in the iOS apps) and may be overridden with
// STREAM_API_KEY. STREAM_API_BASE_URL exists so local tests can point at a
// mock instead of the real Stream backend; it defaults to Stream's edge.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { SignJWT } from "npm:jose@5";

// Same public key the iOS apps embed (shared/Sources/YentlShared/Environment.swift).
const DEFAULT_STREAM_API_KEY = "63zc3wmbpa7v";
const DEFAULT_STREAM_API_BASE_URL = "https://chat.stream-io-api.com";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Small helper: JSON response with status. */
function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
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
    try {
      const body = await req.json();
      matchId = String(body?.match_id ?? "").toLowerCase();
    } catch {
      return json({ error: "invalid JSON body" }, 400);
    }
    if (!UUID_RE.test(matchId)) {
      return json({ error: "match_id must be a UUID" }, 400);
    }

    // -----------------------------------------------------------------------
    // 3. Load the match and authorize. Service-role read so the checks below
    //    are the single source of truth (RLS also lets staff see matches, and
    //    staff must NOT pass — only participants may trigger creation).
    // -----------------------------------------------------------------------
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const streamSecret = Deno.env.get("STREAM_API_SECRET");
    if (!serviceRoleKey || !streamSecret) {
      console.error("stream-channel: missing service-role key or STREAM_API_SECRET");
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
      console.error("stream-channel: match lookup failed:", matchErr.message);
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
    if (match.state !== "confirmed") {
      return json({ error: "match is not confirmed" }, 409);
    }

    // Display names for the Stream user upsert. Missing profiles are not
    // fatal — Stream renders the id if a name is absent, and a chat that
    // opens beats one that 500s over a display name.
    const { data: profiles, error: profErr } = await admin
      .from("profiles")
      .select("id, display_name")
      .in("id", [userA, userB]);
    if (profErr) {
      console.error("stream-channel: profile lookup failed:", profErr.message);
    }
    const nameFor = (id: string): string | undefined =>
      profiles?.find((p) => String(p.id).toLowerCase() === id)?.display_name;

    // -----------------------------------------------------------------------
    // 4. Server-auth token for Stream's REST API: a JWT signed with the API
    //    secret carrying the server claim (no user_id — this is full-access
    //    server auth, which is what permits the user upsert).
    // -----------------------------------------------------------------------
    const serverToken = await new SignJWT({ server: true })
      .setProtectedHeader({ alg: "HS256", typ: "JWT" })
      .setIssuedAt()
      .sign(new TextEncoder().encode(streamSecret));

    const apiKey = Deno.env.get("STREAM_API_KEY") ?? DEFAULT_STREAM_API_KEY;
    const baseURL = (Deno.env.get("STREAM_API_BASE_URL") ??
      DEFAULT_STREAM_API_BASE_URL).replace(/\/+$/, "");
    const streamHeaders = {
      "Content-Type": "application/json",
      "Stream-Auth-Type": "jwt",
      Authorization: serverToken,
    };

    // 4a. Upsert both participants. This is the step the client could never
    // perform: a partner who has never connected does not exist in Stream.
    const upsertRes = await fetch(`${baseURL}/users?api_key=${apiKey}`, {
      method: "POST",
      headers: streamHeaders,
      body: JSON.stringify({
        users: {
          [userA]: { id: userA, name: nameFor(userA) },
          [userB]: { id: userB, name: nameFor(userB) },
        },
      }),
    });
    if (!upsertRes.ok) {
      console.error(
        `stream-channel: user upsert failed (${upsertRes.status}):`,
        (await upsertRes.text()).slice(0, 500),
      );
      return json({ error: "chat backend rejected user upsert" }, 502);
    }

    // 4b. Create-or-ensure the channel. `channels/{type}/{id}/query` creates
    // the channel when it does not exist and returns the existing one when it
    // does — idempotent by design, no created-check needed.
    const channelId = `match-${matchId}`;
    const queryRes = await fetch(
      `${baseURL}/channels/messaging/${channelId}/query?api_key=${apiKey}`,
      {
        method: "POST",
        headers: streamHeaders,
        body: JSON.stringify({
          data: {
            created_by_id: callerId,
            members: [{ user_id: userA }, { user_id: userB }],
          },
        }),
      },
    );
    if (!queryRes.ok) {
      console.error(
        `stream-channel: channel query failed (${queryRes.status}):`,
        (await queryRes.text()).slice(0, 500),
      );
      return json({ error: "chat backend rejected channel creation" }, 502);
    }

    return json(
      { channel_id: channelId, channel_type: "messaging", cid: `messaging:${channelId}` },
      200,
    );
  } catch (err) {
    console.error(
      "stream-channel: unexpected failure:",
      err instanceof Error ? err.message : String(err),
    );
    return json({ error: "internal error" }, 500);
  }
});
