// Phase 12 (Slice 1): screen-profile — AI screening for the profile approval
// pipeline.
//
// Contract: POST { "profile_id": "<uuid>" } with either
//   - the profile OWNER's Supabase JWT (screen-on-submit),
//   - a STAFF user's JWT (matchmaker/admin re-screen), or
//   - the service-role key as the bearer (server-side automation, e.g. the
//     later retroactive review of existing profiles).
//
// What it does:
//   1. authenticates the caller (auth.getUser round-trip, like stream-token,
//      or the service-role key compared verbatim),
//   2. loads the profile's text (display_name, location, bio, prompt answers)
//      and photos (short-lived signed URLs from the private bucket),
//   3. runs the checks:
//        - TEXT   -> OpenAI moderations (`omni-moderation-latest`)
//        - TEXT   -> local contact-info detector (phones/emails/handles/
//                    social-platform mentions — OpenAI's categories do not
//                    cover "trying to move off-platform", so this is ours)
//        - PHOTOS -> OpenAI moderations with image input (NSFW etc.)
//        - PHOTOS -> GPT-4o vision: is this one real person's face?
//                    (faces present, single person, not a screenshot/object)
//   4. aggregates a verdict — 'flagged' if anything flagged, else 'error' if
//      any check failed, else 'clean' — with structured per-check reasons,
//   5. calls the `apply_ai_verdict` RPC (service role; the ONLY path allowed
//      to move review_state from screening) which stores the
//      profile_moderation row and transitions the state machine:
//        approval ON:  clean -> live, flagged -> pending_review,
//                      error -> state unchanged (retry later)
//        approval OFF: -> live (pre-Phase-12 behavior preserved)
//
// Re-screening is idempotent-ish: apply_ai_verdict upserts the single
// profile_moderation row per profile, so the latest verdict wins.
//
// The photo path is kept behind the small PhotoScreener interface below so a
// dedicated vision vendor (Sightengine/Hive) can replace OpenAI later without
// touching the pipeline; today's only implementation is OpenAI.
//
// OpenAI API (verified against the current API reference, 2026-07-22):
//   POST {OPENAI_API_BASE_URL}/moderations
//        { model: "omni-moderation-latest",
//          input: [ {type:"text",text} | {type:"image_url",image_url:{url}} ] }
//     -> { results: [ { flagged, categories: {name: bool}, ... } ] }
//        (results may hold one entry per input or one combined entry; we union
//        every result defensively)
//   POST {OPENAI_API_BASE_URL}/chat/completions
//        { model: "gpt-4o", messages: [...image_url content...],
//          response_format: {type:"json_object"} }
//
// Secrets/env: OPENAI_API_KEY (function secret; NEVER logged),
// OPENAI_API_BASE_URL (override so local tests hit a mock; same pattern as
// STREAM_API_BASE_URL / REVENUECAT_API_BASE_URL), OPENAI_MODERATION_MODEL
// (default omni-moderation-latest), OPENAI_VISION_MODEL (default gpt-4o).
//
// `verify_jwt` is false in config.toml for the same reasons documented in
// stream-token: the function authenticates callers itself (auth.getUser or
// the service-role key), which is stricter than the gateway check.

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";

const DEFAULT_OPENAI_API_BASE_URL = "https://api.openai.com/v1";
const DEFAULT_MODERATION_MODEL = "omni-moderation-latest";
const DEFAULT_VISION_MODEL = "gpt-4o";
const SIGNED_URL_TTL_SECONDS = 600;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Contact-info detector. OpenAI's moderation categories do not flag "text me
// on WhatsApp" — but moving conversations off-platform before a matchmaker-
// confirmed date is exactly what Yentl moderates. Heuristics, deliberately a
// bit eager: a false positive only routes the profile to human review.
// ---------------------------------------------------------------------------
interface ContactInfoHit {
  kind: string;
  sample: string;
}

function detectContactInfo(text: string): ContactInfoHit[] {
  const hits: ContactInfoHit[] = [];
  const push = (kind: string, match: string | undefined) => {
    if (match) hits.push({ kind, sample: match.trim().slice(0, 40) });
  };

  const email = text.match(/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/i);
  push("email", email?.[0]);

  // 7+ digits, allowing separators — matches phone numbers without matching
  // ages/heights/years.
  const phoneCandidates = text.match(/\+?\d[\d\s().\-]{5,}\d/g) ?? [];
  const phone = phoneCandidates.find(
    (c) => (c.match(/\d/g)?.length ?? 0) >= 7,
  );
  push("phone", phone);

  const url = text.match(/(?:https?:\/\/|www\.)\S+/i);
  push("url", url?.[0]);

  const handle = text.match(/(?:^|[\s(:,])@[a-z0-9_.]{3,}/i);
  push("handle", handle?.[0]);

  const platform = text.match(
    /\b(instagram|insta|snapchat|snap\s?chat|telegram|whats\s?app|tiktok|signal|kik|onlyfans|facebook|discord|wechat)\b/i,
  );
  push("social_platform", platform?.[0]);

  const comeFindMe = text.match(
    /\b(?:find|add|follow|dm|hit\s+up|message|text)\s+me\b/i,
  );
  push("off_platform_invite", comeFindMe?.[0]);

  return hits;
}

// ---------------------------------------------------------------------------
// OpenAI client bits (moderations + vision), all pointed at an overridable
// base URL so local tests can run against a mock.
// ---------------------------------------------------------------------------
interface OpenAIConfig {
  baseURL: string;
  apiKey: string;
  moderationModel: string;
  visionModel: string;
}

type ModerationInput =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };

interface ModerationOutcome {
  flagged: boolean;
  categories: string[];
}

/** POST /moderations, unioning flagged categories over every result entry. */
async function moderate(
  cfg: OpenAIConfig,
  input: ModerationInput[],
): Promise<ModerationOutcome> {
  const res = await fetch(`${cfg.baseURL}/moderations`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${cfg.apiKey}`,
    },
    body: JSON.stringify({ model: cfg.moderationModel, input }),
  });
  if (!res.ok) {
    throw new Error(
      `moderations failed (${res.status}): ${(await res.text()).slice(0, 300)}`,
    );
  }
  const body = await res.json();
  const results: Array<Record<string, unknown>> = Array.isArray(body?.results)
    ? body.results
    : [];
  const categories = new Set<string>();
  let flagged = false;
  for (const r of results) {
    if (r.flagged === true) flagged = true;
    const cats = r.categories;
    if (cats && typeof cats === "object") {
      for (const [name, hit] of Object.entries(cats as Record<string, unknown>)) {
        if (hit === true) categories.add(name);
      }
    }
  }
  return { flagged, categories: [...categories].sort() };
}

interface FaceCheck {
  faces_present: boolean;
  single_person: boolean;
  appears_real_photo: boolean;
  flagged: boolean;
  notes?: string;
}

/** GPT-4o vision: is this one real person's face? */
async function checkFace(cfg: OpenAIConfig, imageURL: string): Promise<FaceCheck> {
  const res = await fetch(`${cfg.baseURL}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${cfg.apiKey}`,
    },
    body: JSON.stringify({
      model: cfg.visionModel,
      temperature: 0,
      max_tokens: 200,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content:
            "You review dating-profile photos. Reply ONLY with a JSON object: " +
            '{"faces_present": bool (at least one human face is visible), ' +
            '"single_person": bool (exactly one person appears), ' +
            '"appears_real_photo": bool (a genuine photo of a person — not a ' +
            "screenshot, meme, drawing, object, text image, or AI render), " +
            '"notes": short string}.',
        },
        {
          role: "user",
          content: [
            { type: "text", text: "Assess this profile photo." },
            { type: "image_url", image_url: { url: imageURL } },
          ],
        },
      ],
    }),
  });
  if (!res.ok) {
    throw new Error(
      `vision check failed (${res.status}): ${(await res.text()).slice(0, 300)}`,
    );
  }
  const body = await res.json();
  const content = body?.choices?.[0]?.message?.content;
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(String(content));
  } catch {
    throw new Error("vision check returned non-JSON content");
  }
  const facesPresent = parsed.faces_present === true;
  const singlePerson = parsed.single_person === true;
  const appearsReal = parsed.appears_real_photo === true;
  return {
    faces_present: facesPresent,
    single_person: singlePerson,
    appears_real_photo: appearsReal,
    flagged: !(facesPresent && singlePerson && appearsReal),
    notes: typeof parsed.notes === "string" ? parsed.notes.slice(0, 200) : undefined,
  };
}

// ---------------------------------------------------------------------------
// PhotoScreener — the pluggable seam. Everything photo-specific goes through
// this interface; swapping in Sightengine/Hive later means one new class and
// one changed line in makePhotoScreener().
// ---------------------------------------------------------------------------
interface PhotoScreenResult {
  moderation: ModerationOutcome;
  face: FaceCheck;
}

interface PhotoScreener {
  screen(imageURL: string): Promise<PhotoScreenResult>;
}

class OpenAIPhotoScreener implements PhotoScreener {
  constructor(private cfg: OpenAIConfig) {}
  async screen(imageURL: string): Promise<PhotoScreenResult> {
    const moderation = await moderate(this.cfg, [
      { type: "image_url", image_url: { url: imageURL } },
    ]);
    const face = await checkFace(this.cfg, imageURL);
    return { moderation, face };
  }
}

function makePhotoScreener(cfg: OpenAIConfig): PhotoScreener {
  return new OpenAIPhotoScreener(cfg);
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  try {
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const apiKey = Deno.env.get("OPENAI_API_KEY");
    if (!serviceRoleKey || !apiKey) {
      console.error(
        "screen-profile: missing service-role key or OPENAI_API_KEY",
      );
      return json({ error: "server misconfigured" }, 500);
    }
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceRoleKey, {
      auth: { persistSession: false },
    }) as SupabaseClient;

    // -----------------------------------------------------------------------
    // 1. Authenticate: service-role key, or a user JWT (owner or staff).
    // -----------------------------------------------------------------------
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return json({ error: "missing authorization" }, 401);
    }
    const bearer = authHeader.slice("Bearer ".length);

    let callerId: string | null = null; // null = service caller
    if (bearer !== serviceRoleKey) {
      const anon = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_ANON_KEY")!,
      );
      const { data, error } = await anon.auth.getUser(bearer);
      if (error || !data?.user) {
        return json({ error: "invalid or expired session" }, 401);
      }
      callerId = data.user.id.toLowerCase();
    }

    // -----------------------------------------------------------------------
    // 2. Parse and authorize.
    // -----------------------------------------------------------------------
    let profileId: string;
    try {
      const body = await req.json();
      profileId = String(body?.profile_id ?? "").toLowerCase();
    } catch {
      return json({ error: "invalid JSON body" }, 400);
    }
    if (!UUID_RE.test(profileId)) {
      return json({ error: "profile_id must be a UUID" }, 400);
    }

    if (callerId !== null && callerId !== profileId) {
      const { data: caller, error: roleErr } = await admin
        .from("users")
        .select("role")
        .eq("id", callerId)
        .maybeSingle();
      if (roleErr) {
        console.error("screen-profile: role lookup failed:", roleErr.message);
        return json({ error: "internal error" }, 500);
      }
      if (caller?.role !== "matchmaker" && caller?.role !== "admin") {
        return json({ error: "not allowed to screen this profile" }, 403);
      }
    }

    // -----------------------------------------------------------------------
    // 3. Load the profile's content.
    // -----------------------------------------------------------------------
    const { data: profile, error: profileErr } = await admin
      .from("profiles")
      .select("id, display_name, location, bio")
      .eq("id", profileId)
      .maybeSingle();
    if (profileErr) {
      console.error("screen-profile: profile lookup failed:", profileErr.message);
      return json({ error: "internal error" }, 500);
    }
    if (!profile) {
      return json({ error: "profile not found" }, 404);
    }

    const { data: prompts, error: promptsErr } = await admin
      .from("profile_prompts")
      .select("prompt, answer")
      .eq("user_id", profileId)
      .order("order_index");
    if (promptsErr) {
      console.error("screen-profile: prompts lookup failed:", promptsErr.message);
      return json({ error: "internal error" }, 500);
    }

    const { data: photos, error: photosErr } = await admin
      .from("profile_photos")
      .select("id, storage_path")
      .eq("user_id", profileId)
      .order("order_index");
    if (photosErr) {
      console.error("screen-profile: photos lookup failed:", photosErr.message);
      return json({ error: "internal error" }, 500);
    }

    const textParts: string[] = [
      String(profile.display_name ?? ""),
      String(profile.location ?? ""),
      String(profile.bio ?? ""),
      ...(prompts ?? []).map((p) => `${p.prompt}\n${p.answer}`),
    ].filter((t) => t.trim().length > 0);

    // -----------------------------------------------------------------------
    // 4. Run the checks.
    // -----------------------------------------------------------------------
    const cfg: OpenAIConfig = {
      baseURL: (Deno.env.get("OPENAI_API_BASE_URL") ??
        DEFAULT_OPENAI_API_BASE_URL).replace(/\/+$/, ""),
      apiKey,
      moderationModel: Deno.env.get("OPENAI_MODERATION_MODEL") ??
        DEFAULT_MODERATION_MODEL,
      visionModel: Deno.env.get("OPENAI_VISION_MODEL") ?? DEFAULT_VISION_MODEL,
    };
    const photoScreener = makePhotoScreener(cfg);

    const errors: string[] = [];

    // 4a. Text moderation (one call for all parts).
    let textOutcome: ModerationOutcome | null = null;
    if (textParts.length > 0) {
      try {
        textOutcome = await moderate(
          cfg,
          textParts.map((t) => ({ type: "text", text: t })),
        );
      } catch (err) {
        errors.push(
          `text moderation: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    } else {
      textOutcome = { flagged: false, categories: [] };
    }

    // 4b. Contact-info detector (local, cannot fail).
    const contactHits = textParts.flatMap((t) => detectContactInfo(t));

    // 4c. Photos: NSFW moderation + single-real-face vision check, per photo.
    const photoReports: Array<Record<string, unknown>> = [];
    let anyPhotoFlagged = false;
    for (const photo of photos ?? []) {
      const { data: signed, error: signErr } = await admin.storage
        .from("profile-photos")
        .createSignedUrl(photo.storage_path, SIGNED_URL_TTL_SECONDS);
      if (signErr || !signed?.signedUrl) {
        errors.push(`photo ${photo.id}: could not sign URL`);
        photoReports.push({ photo_id: photo.id, error: "could not sign URL" });
        continue;
      }
      try {
        const result = await photoScreener.screen(signed.signedUrl);
        const flagged = result.moderation.flagged || result.face.flagged;
        if (flagged) anyPhotoFlagged = true;
        photoReports.push({
          photo_id: photo.id,
          flagged,
          moderation: {
            flagged: result.moderation.flagged,
            categories: result.moderation.categories,
          },
          face: result.face,
        });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        errors.push(`photo ${photo.id}: ${msg}`);
        photoReports.push({ photo_id: photo.id, error: msg });
      }
    }

    // -----------------------------------------------------------------------
    // 5. Aggregate. Flagged beats error (a flagged profile goes to human
    //    review anyway); error means "checks incomplete, retry later".
    // -----------------------------------------------------------------------
    const contactFlagged = contactHits.length > 0;
    const textFlagged = textOutcome?.flagged === true;
    const anyFlagged = textFlagged || contactFlagged || anyPhotoFlagged;
    const verdict = anyFlagged ? "flagged" : errors.length > 0 ? "error" : "clean";

    const reasons = {
      text: {
        flagged: textFlagged,
        categories: textOutcome?.categories ?? [],
        parts_checked: textParts.length,
      },
      contact_info: { flagged: contactFlagged, matches: contactHits },
      photos: photoReports,
      photos_checked: (photos ?? []).length,
      errors,
      models: {
        moderation: cfg.moderationModel,
        vision: cfg.visionModel,
      },
    };

    // -----------------------------------------------------------------------
    // 6. Record + transition through the state machine.
    // -----------------------------------------------------------------------
    const { data: newState, error: rpcErr } = await admin.rpc(
      "apply_ai_verdict",
      { p_profile_id: profileId, p_verdict: verdict, p_reasons: reasons },
    );
    if (rpcErr) {
      console.error("screen-profile: apply_ai_verdict failed:", rpcErr.message);
      return json({ error: "internal error" }, 500);
    }

    return json(
      { verdict, review_state: newState, reasons },
      verdict === "error" ? 502 : 200,
    );
  } catch (err) {
    console.error(
      "screen-profile: unexpected failure:",
      err instanceof Error ? err.message : String(err),
    );
    return json({ error: "internal error" }, 500);
  }
});
