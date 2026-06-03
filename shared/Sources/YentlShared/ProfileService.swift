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

/// Reads and writes the signed-in user's profile in `public.profiles`.
///
/// Used from SwiftUI as `@Environment(ProfileService.self)`; the host app
/// injects `ProfileService.shared`. Mirrors `AuthService` — all Supabase
/// access stays inside the package.
@MainActor
@Observable
public final class ProfileService {
    public static let shared = ProfileService()

    private init() {}

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

    /// Saves the profile basics for the current user and marks the profile
    /// complete. Slice 1 has a single step, so finishing it completes the
    /// profile; later slices will move completion to the final wizard step.
    public func saveBasics(
        displayName: String,
        dateOfBirth: String,
        gender: Gender,
        location: String
    ) async throws {
        let userID = try await currentUserID()
        let profile = Profile(
            id: userID,
            displayName: displayName,
            dateOfBirth: dateOfBirth,
            gender: gender,
            location: location,
            profileCompletedAt: Date()
        )
        do {
            try await Backend.supabase
                .from("profiles")
                .upsert(profile)
                .execute()
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
}
