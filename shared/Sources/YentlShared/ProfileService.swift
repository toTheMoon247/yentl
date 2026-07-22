import Foundation
import Observation
import Supabase

/// Profile-related errors surfaced to the UI.
public enum ProfileError: LocalizedError {
    case notSignedIn
    case unexpected(any Error)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .unexpected(let error):
            return error.localizedDescription
        }
    }
}

/// Reads and writes the signed-in user's profile in `public.profiles` and
/// their photos in `public.profile_photos` + the `profile-photos` Storage
/// bucket.
///
/// Used from SwiftUI as `@Environment(ProfileService.self)`; the host app
/// injects `ProfileService.shared`. Mirrors `AuthService` — all Supabase
/// access stays inside the package.
@MainActor
@Observable
public final class ProfileService {
    public static let shared = ProfileService()

    private let photoBucket = "profile-photos"

    private init() {}

    // MARK: - Profile basics

    /// Whether the signed-in user has finished the profile creation wizard
    /// (backed by `profiles.profile_completed_at`). Returns false when no
    /// profile row exists yet.
    public func isProfileComplete() async throws -> Bool {
        let userID = try await currentUserID()
        do {
            // Array + limit(1) rather than .single() so a missing row is "false"
            // instead of an error (a brand-new user has no profile yet).
            let rows: [CompletionRow] = try await Backend.supabase
                .from("profiles")
                .select("profile_completed_at")
                .eq("id", value: userID)
                .limit(1)
                .execute()
                .value
            return rows.first?.profileCompletedAt != nil
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// Inserts or updates the profile basics. Does NOT mark the profile
    /// complete — completion happens at the end of the wizard via
    /// `markProfileComplete()`.
    public func saveBasics(
        displayName: String,
        dateOfBirth: String,
        gender: Gender,
        location: String
    ) async throws {
        let userID = try await currentUserID()
        let payload = BasicsPayload(
            id: userID,
            displayName: displayName,
            dateOfBirth: dateOfBirth,
            gender: gender,
            location: location
        )
        do {
            try await Backend.supabase
                .from("profiles")
                .upsert(payload)
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// Saves bio, interests, and prompts (the optional "about you" details).
    /// Prompts are replaced wholesale (delete + insert) for simplicity.
    public func saveDetails(
        bio: String?,
        interests: [String],
        prompts: [ProfilePromptDraft]
    ) async throws {
        let userID = try await currentUserID()
        do {
            try await Backend.supabase
                .from("profiles")
                .update(DetailsPayload(bio: bio, interests: interests))
                .eq("id", value: userID)
                .execute()

            try await Backend.supabase
                .from("profile_prompts")
                .delete()
                .eq("user_id", value: userID)
                .execute()

            let rows = prompts.enumerated().map { index, draft in
                ProfilePrompt(
                    id: UUID(),
                    userId: userID,
                    prompt: draft.prompt,
                    answer: draft.answer,
                    orderIndex: index
                )
            }
            if !rows.isEmpty {
                try await Backend.supabase
                    .from("profile_prompts")
                    .insert(rows)
                    .execute()
            }
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// Saves the hidden matchmaker fields (height, income). Required to finish.
    public func savePrivateDetails(heightCm: Int, incomeAnnual: Int) async throws {
        let userID = try await currentUserID()
        do {
            try await Backend.supabase
                .from("profiles")
                .update(PrivatePayload(heightCm: heightCm, incomeAnnual: incomeAnnual))
                .eq("id", value: userID)
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// Stamps `profile_completed_at` and submits the profile: the write of
    /// `review_state = 'live'` takes effect directly while approval is OFF
    /// (today's behavior), and is coerced to `pending_ai` by the server's
    /// `enforce_review_state` trigger while approval is ON. Also the
    /// "resubmit" call after a rejection — same write, same coercion.
    public func markProfileComplete() async throws {
        let userID = try await currentUserID()
        do {
            try await Backend.supabase
                .from("profiles")
                .update(CompletionPayload(profileCompletedAt: Date()))
                .eq("id", value: userID)
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    // MARK: - Review state (Phase 12)

    /// The signed-in user's `profiles.review_state`, or nil when no profile
    /// row exists yet (or the server holds a value this build doesn't know —
    /// treated like "no gate", so an app update can't lock users out).
    public func fetchMyReviewState() async throws -> ProfileReviewState? {
        let userID = try await currentUserID()
        do {
            let rows: [ReviewStateRow] = try await Backend.supabase
                .from("profiles")
                .select("review_state")
                .eq("id", value: userID)
                .limit(1)
                .execute()
                .value
            return rows.first.flatMap { ProfileReviewState(rawValue: $0.reviewState) }
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// The signed-in user's own `profile_moderation` row (RLS allows owner
    /// reads), or nil when no screening/decision has ever been recorded.
    /// Carries `decisionReason` for the "profile needs changes" screen.
    public func fetchMyModeration() async throws -> MyModerationStatus? {
        let userID = try await currentUserID()
        do {
            let rows: [MyModerationStatus] = try await Backend.supabase
                .from("profile_moderation")
                .select("decision, decision_reason")
                .eq("profile_id", value: userID)
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// Best-effort request for AI screening of the signed-in user's profile
    /// (the `screen-profile` Edge Function, invoked with the owner's JWT).
    ///
    /// Deliberately non-throwing: screening failing (function not deployed
    /// yet, OPENAI_API_KEY unset, network down) must never strand the user —
    /// the caller re-reads `review_state` afterwards and routes on whatever
    /// the server actually holds. With approval OFF the call is harmless
    /// either way: completion already wrote `live`.
    @discardableResult
    public func requestScreening() async -> Bool {
        do {
            let userID = try await currentUserID()
            try await Backend.supabase.functions.invoke(
                "screen-profile",
                options: FunctionInvokeOptions(
                    method: .post,
                    body: ScreenProfileRequest(profileID: userID)
                )
            )
            return true
        } catch {
            // Swallowed by design — see above. The state re-read is the truth.
            return false
        }
    }

    // MARK: - Photos

    // MARK: - Reads (own profile + staff browsing)

    /// The signed-in user's full profile, or nil if none exists yet.
    public func fetchMyProfile() async throws -> Profile? {
        try await fetchProfile(userID: currentUserID())
    }

    /// A specific user's profile. The owner sees their own; staff
    /// (matchmaker/admin) can read anyone's (RLS).
    public func fetchProfile(userID: UUID) async throws -> Profile? {
        do {
            let rows: [Profile] = try await Backend.supabase
                .from("profiles")
                .select()
                .eq("id", value: userID)
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// All completed profiles, newest first. For the matchmaker app (staff RLS
    /// returns everyone; a regular user would only get their own row).
    public func fetchAllCompletedProfiles() async throws -> [Profile] {
        do {
            let all: [Profile] = try await Backend.supabase
                .from("profiles")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            return all.filter { $0.profileCompletedAt != nil }
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// The current user's photos, ordered for display.
    public func listPhotos() async throws -> [ProfilePhoto] {
        try await listPhotos(userID: currentUserID())
    }

    /// A specific user's photos, ordered for display (owner or staff).
    public func listPhotos(userID: UUID) async throws -> [ProfilePhoto] {
        do {
            return try await Backend.supabase
                .from("profile_photos")
                .select()
                .eq("user_id", value: userID)
                .order("order_index", ascending: true)
                .execute()
                .value
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// A specific user's answered prompts, ordered (owner or staff).
    public func listPrompts(userID: UUID) async throws -> [ProfilePrompt] {
        do {
            return try await Backend.supabase
                .from("profile_prompts")
                .select()
                .eq("user_id", value: userID)
                .order("order_index", ascending: true)
                .execute()
                .value
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// Uploads a JPEG (already downscaled/encoded by the caller) and appends a
    /// `profile_photos` row at the end of the user's photo order. Returns the
    /// new row.
    @discardableResult
    public func uploadPhoto(jpegData: Data) async throws -> ProfilePhoto {
        let userID = try await currentUserID()
        let photoID = UUID()
        // Lowercase to match Postgres `auth.uid()::text` (Swift's uuidString is
        // uppercase): the storage RLS scopes access by the first path segment
        // == the caller's uid, so a case mismatch would fail the policy.
        let path = "\(userID.uuidString.lowercased())/\(photoID.uuidString.lowercased()).jpg"
        do {
            let nextIndex = try await listPhotos().count
            try await Backend.supabase.storage
                .from(photoBucket)
                .upload(path, data: jpegData, options: FileOptions(contentType: "image/jpeg"))

            let photo = ProfilePhoto(
                id: photoID,
                userId: userID,
                storagePath: path,
                orderIndex: nextIndex
            )
            try await Backend.supabase
                .from("profile_photos")
                .insert(photo)
                .execute()
            return photo
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// Deletes a photo: removes the stored file and the row.
    public func deletePhoto(_ photo: ProfilePhoto) async throws {
        do {
            try await Backend.supabase.storage
                .from(photoBucket)
                .remove(paths: [photo.storagePath])
            try await Backend.supabase
                .from("profile_photos")
                .delete()
                .eq("id", value: photo.id)
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// Persists a new display order. `ordered` is the photos in their desired
    /// order; each row's `order_index` is set to its position.
    public func reorderPhotos(_ ordered: [ProfilePhoto]) async throws {
        do {
            for (index, photo) in ordered.enumerated() where photo.orderIndex != index {
                try await Backend.supabase
                    .from("profile_photos")
                    .update(OrderPayload(orderIndex: index))
                    .eq("id", value: photo.id)
                    .execute()
            }
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    /// A short-lived signed URL for displaying a photo from the private bucket.
    public func signedPhotoURL(for storagePath: String) async throws -> URL {
        do {
            return try await Backend.supabase.storage
                .from(photoBucket)
                .createSignedURL(path: storagePath, expiresIn: 3600)
        } catch {
            if error is CancellationError { throw error }
            throw ProfileError.unexpected(error)
        }
    }

    // MARK: - Private

    private func currentUserID() async throws -> UUID {
        do {
            return try await Backend.supabase.auth.session.user.id
        } catch {
            throw ProfileError.notSignedIn
        }
    }

    private struct CompletionRow: Decodable {
        let profileCompletedAt: String?

        enum CodingKeys: String, CodingKey {
            case profileCompletedAt = "profile_completed_at"
        }
    }

    /// Decoded as a raw string (not `ProfileReviewState`) so an unknown
    /// future state degrades to nil instead of a decoding error.
    private struct ReviewStateRow: Decodable {
        let reviewState: String

        enum CodingKeys: String, CodingKey {
            case reviewState = "review_state"
        }
    }

    /// Body of the `screen-profile` invocation. The function validates the
    /// id against a lowercase-only UUID regex, so the uppercase
    /// `UUID.uuidString` must be lowercased here.
    struct ScreenProfileRequest: Encodable {
        let profileID: String

        init(profileID: UUID) {
            self.profileID = profileID.uuidString.lowercased()
        }

        enum CodingKeys: String, CodingKey {
            case profileID = "profile_id"
        }
    }

    private struct BasicsPayload: Encodable {
        let id: UUID
        let displayName: String
        let dateOfBirth: String
        let gender: Gender
        let location: String

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case dateOfBirth = "date_of_birth"
            case gender
            case location
        }
    }

    private struct CompletionPayload: Encodable {
        let profileCompletedAt: Date
        // Writing 'live' is the submission protocol (see markProfileComplete):
        // it sticks while approval is OFF; the enforce_review_state trigger
        // turns it into 'pending_ai' while approval is ON.
        let reviewState = "live"

        enum CodingKeys: String, CodingKey {
            case profileCompletedAt = "profile_completed_at"
            case reviewState = "review_state"
        }
    }

    private struct DetailsPayload: Encodable {
        let bio: String?
        let interests: [String]
    }

    private struct PrivatePayload: Encodable {
        let heightCm: Int
        let incomeAnnual: Int

        enum CodingKeys: String, CodingKey {
            case heightCm = "height_cm"
            case incomeAnnual = "income_annual"
        }
    }

    private struct OrderPayload: Encodable {
        let orderIndex: Int

        enum CodingKeys: String, CodingKey {
            case orderIndex = "order_index"
        }
    }
}
