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
            throw ProfileError.unexpected(error)
        }
    }

    /// Stamps `profile_completed_at`, marking the profile live (MVP).
    public func markProfileComplete() async throws {
        let userID = try await currentUserID()
        do {
            try await Backend.supabase
                .from("profiles")
                .update(CompletionPayload(profileCompletedAt: Date()))
                .eq("id", value: userID)
                .execute()
        } catch {
            throw ProfileError.unexpected(error)
        }
    }

    // MARK: - Photos

    /// The user's photos, ordered for display.
    public func listPhotos() async throws -> [ProfilePhoto] {
        let userID = try await currentUserID()
        do {
            return try await Backend.supabase
                .from("profile_photos")
                .select()
                .eq("user_id", value: userID)
                .order("order_index", ascending: true)
                .execute()
                .value
        } catch {
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

        enum CodingKeys: String, CodingKey {
            case profileCompletedAt = "profile_completed_at"
        }
    }

    private struct OrderPayload: Encodable {
        let orderIndex: Int

        enum CodingKeys: String, CodingKey {
            case orderIndex = "order_index"
        }
    }
}
