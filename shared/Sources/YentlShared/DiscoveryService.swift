import Foundation
import Observation
import Supabase

/// Discovery-related errors surfaced to the UI.
public enum DiscoveryError: LocalizedError {
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

/// Discovery feed + swipe recording for the Yentl consumer app.
///
/// The feed comes from the `discovery_feed` RPC — a security-definer projection
/// that returns only public profile fields (never the hidden matchmaker
/// height/income). Swipes are recorded but never surfaced back to the user;
/// received-like data is the matchmaker's (Phase 5).
@MainActor
@Observable
public final class DiscoveryService {
    public static let shared = DiscoveryService()

    private init() {}

    /// Candidate profiles for the signed-in user (live, opposite gender, not yet
    /// swiped). Returns `Profile`s with only public fields populated.
    public func fetchFeed(limit: Int = 20) async throws -> [Profile] {
        do {
            return try await Backend.supabase
                .rpc("discovery_feed", params: FeedParams(limitCount: limit))
                .execute()
                .value
        } catch {
            throw DiscoveryError.unexpected(error)
        }
    }

    /// Records a like/pass on a candidate. Idempotent at the DB level via the
    /// unique (from_user, to_user) constraint.
    public func recordSwipe(toUserID: UUID, action: SwipeAction) async throws {
        let fromUser = try await currentUserID()
        do {
            try await Backend.supabase
                .from("swipes")
                .insert(SwipeInsert(fromUser: fromUser, toUser: toUserID, action: action))
                .execute()
        } catch {
            throw DiscoveryError.unexpected(error)
        }
    }

    // MARK: - Private

    private func currentUserID() async throws -> UUID {
        do {
            return try await Backend.supabase.auth.session.user.id
        } catch {
            throw DiscoveryError.notSignedIn
        }
    }

    private struct FeedParams: Encodable {
        let limitCount: Int

        enum CodingKeys: String, CodingKey {
            case limitCount = "limit_count"
        }
    }

    private struct SwipeInsert: Encodable {
        let fromUser: UUID
        let toUser: UUID
        let action: SwipeAction

        enum CodingKeys: String, CodingKey {
            case fromUser = "from_user"
            case toUser = "to_user"
            case action
        }
    }
}
