// delete-account — permanent account deletion (App Store 5.1.1 / GDPR erasure).
//
// POST with the caller's Supabase JWT in Authorization. The function:
//   1. verifies the JWT (auth.getUser round-trip, exactly like stream-token /
//      record-payment) — a user can only ever delete THEMSELVES;
//   2. deletes their Storage photos (profile-photos/{uid}/*) via the service
//      role — Storage blocks direct SQL deletes, so this must go through the
//      Storage API;
//   3. deletes public.users, which cascades every app table (profiles →
//      photos/moderation, swipes, matches, payments, reports, blocks, queue,
//      prefs, moderation_actions — see the FK map);
//   4. deletes the auth.users row (and its identities/sessions) via the admin
//      API. public.users has NO FK to auth.users, so 3 and 4 are separate.
//
// Steps 2-4 are ordered so a mid-failure never leaves a usable account with
// orphaned data: app data goes first, the login last. Deleting an already-gone
// row is a no-op, so a retry is safe.
//
// `verify_jwt` is false in config.toml (same as the other functions): the
// function authenticates the caller itself via auth.getUser(), which is
// stricter than the gateway's opaque check. No custom secrets — only the
// auto-injected SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

const PHOTO_BUCKET = "profile-photos";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceRoleKey) {
    return json({ error: "server misconfigured" }, 500);
  }

  // 1. Authenticate the caller — they can only delete themselves.
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "missing authorization" }, 401);
  }
  const bearer = authHeader.slice("Bearer ".length);
  const anon = createClient(url, anonKey);
  const { data: userData, error: authError } = await anon.auth.getUser(bearer);
  if (authError || !userData?.user) {
    return json({ error: "invalid or expired session" }, 401);
  }
  const uid = userData.user.id;

  const admin = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    // 2. Storage photos (best-effort: a storage failure must not block erasure
    //    of the account itself — the row deletion is what matters legally).
    const { data: objects } = await admin.storage.from(PHOTO_BUCKET).list(uid, {
      limit: 100,
    });
    if (objects && objects.length > 0) {
      const paths = objects.map((o) => `${uid}/${o.name}`);
      await admin.storage.from(PHOTO_BUCKET).remove(paths);
    }

    // 3. App data (cascades across every table that references the user).
    const { error: dataError } = await admin.from("users").delete().eq("id", uid);
    if (dataError) {
      return json({ error: "failed to delete account data", detail: dataError.message }, 500);
    }

    // 4. The auth identity itself (removes login, identities, sessions).
    const { error: authDeleteError } = await admin.auth.admin.deleteUser(uid);
    if (authDeleteError) {
      return json(
        { error: "account data deleted but auth removal failed; retry",
          detail: authDeleteError.message },
        500,
      );
    }

    return json({ deleted: true });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
