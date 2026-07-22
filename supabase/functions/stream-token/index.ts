// Phase 7 (Slice 1): stream-token — issues Stream Chat user tokens.
//
// Stream Chat authenticates users with a JWT signed HS256 by the app's API
// *secret*, carrying a `user_id` claim (Stream docs also recommend `exp` and
// `iat`; `iat` is what makes server-side token revocation possible). The
// secret must never ship in the client, so this function is the only place a
// token can be minted: the iOS apps call it, then hand the token to the
// Stream Swift SDK's token provider.
//
// THE SECURITY PROPERTY THAT MATTERS: the Stream user id is derived solely
// from the caller's verified Supabase session (the Authorization: Bearer
// JWT), never from the request body or query string. If callers could name
// their own id, anyone could mint a token impersonating any user. The request
// body is deliberately never read.
//
// JWT verification happens in-function via auth.getUser() — a round-trip to
// the Auth server that checks signature, expiry and revocation — rather than
// relying on the platform's gateway `verify_jwt` flag. Two reasons:
//   1. The gateway check only proves the JWT was signed with the project's
//      JWT secret; locally (and on legacy projects) the *anon key* is such a
//      JWT, so the gateway alone would let unauthenticated callers through.
//   2. It keeps the function correct regardless of gateway configuration or
//      a future migration to asymmetric JWT signing keys.
// `verify_jwt` is therefore set to false for this function in config.toml,
// and the deploy must pass --no-verify-jwt (or rely on config.toml, which
// recent CLI versions read on deploy).
//
// Secrets: STREAM_API_SECRET is a Supabase function secret (already set on
// the hosted project; supplied via --env-file when serving locally). It is
// never logged and never included in any response.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { SignJWT } from "npm:jose@5";

// One hour, mirroring the Supabase session lifetime (auth.jwt_expiry = 3600).
// Short enough that a leaked token ages out quickly; the Stream Swift SDK's
// token provider transparently calls back here for a fresh one on expiry, so
// a short lifetime costs the user nothing.
const TOKEN_TTL_SECONDS = 60 * 60;

/** Small helper: JSON response with status. */
function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  // The iOS clients invoke functions with POST (supabase-swift's default).
  // No CORS/OPTIONS handling: there is no browser client.
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  try {
    // -----------------------------------------------------------------------
    // 1. Authenticate the caller. No valid Supabase user JWT → 401.
    // -----------------------------------------------------------------------
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return json({ error: "missing authorization" }, 401);
    }
    const supabaseJWT = authHeader.slice("Bearer ".length);

    // SUPABASE_URL / SUPABASE_ANON_KEY are injected automatically, both by
    // `supabase functions serve` and on the hosted platform.
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
    );

    // Round-trip to the Auth server: verifies signature, expiry and
    // revocation. The anon key itself has no user, so it fails here too.
    const { data, error } = await supabase.auth.getUser(supabaseJWT);
    if (error || !data?.user) {
      return json({ error: "invalid or expired session" }, 401);
    }

    // The ONLY source of the Stream user id. Stream ids are strings; ours is
    // the Supabase auth user UUID, the same id the rest of the schema keys on.
    const userId = data.user.id;

    // -----------------------------------------------------------------------
    // 2. Mint the Stream user token.
    // -----------------------------------------------------------------------
    const secret = Deno.env.get("STREAM_API_SECRET");
    if (!secret) {
      // Misconfiguration, not a caller error. Say so without detail.
      console.error("stream-token: STREAM_API_SECRET is not set");
      return json({ error: "server misconfigured" }, 500);
    }

    const nowEpoch = Math.floor(Date.now() / 1000);
    const expiresAtEpoch = nowEpoch + TOKEN_TTL_SECONDS;

    const streamToken = await new SignJWT({ user_id: userId })
      .setProtectedHeader({ alg: "HS256", typ: "JWT" })
      .setIssuedAt(nowEpoch)
      .setExpirationTime(expiresAtEpoch)
      .sign(new TextEncoder().encode(secret));

    // expires_at lets the client schedule a refresh instead of waiting to be
    // rejected; user_id is echoed so the client can pass it to connectUser
    // without re-deriving it.
    return json(
      { token: streamToken, user_id: userId, expires_at: expiresAtEpoch },
      200,
    );
  } catch (err) {
    // Log the message only — never the request headers or any env value.
    console.error(
      "stream-token: unexpected failure:",
      err instanceof Error ? err.message : String(err),
    );
    return json({ error: "internal error" }, 500);
  }
});
