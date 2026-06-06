import Foundation
import Observation
import Supabase

/// Matchmaker-side errors surfaced to the UI.
public enum MatchmakerError: LocalizedError {
    case unexpected(any Error)

    public var errorDescription: String? {
        switch self {
        case .unexpected(let error):
            return error.localizedDescription
        }
    }
}

/// Likes a user has received vs given — drives the empty-candidate diagnostic
/// (Boost when not receiving, Skip when not giving).
public struct LikeStats: Sendable, Equatable {
    public let received: Int
    public let given: Int

    public init(received: Int, given: Int) {
        self.received = received
        self.given = given
    }
}

/// Decision Panel data for the Yentl Matchmaker app. All calls go through
/// staff-only security-definer RPCs.
@MainActor
@Observable
public final class MatchmakerService {
    public static let shared = MatchmakerService()

    private init() {}

    /// The front-of-queue user to pin (M/F alternating), or nil if the queue
    /// is empty.
    public func nextQueuedUser() async throws -> UUID? {
        do {
            return try await Backend.supabase
                .rpc("next_queued_user")
                .execute()
                .value
        } catch {
            if error is CancellationError { throw error }
            throw MatchmakerError.unexpected(error)
        }
    }

    /// The active queue in pin order (for the Queue tab).
    public func queuedProfiles() async throws -> [Profile] {
        do {
            return try await Backend.supabase
                .rpc("queued_profiles")
                .execute()
                .value
        } catch {
            if error is CancellationError { throw error }
            throw MatchmakerError.unexpected(error)
        }
    }

    /// Mutual-like candidates for the pinned user (people who liked them and
    /// whom they also liked), most-recent-mutual first.
    public func candidates(for pinnedID: UUID) async throws -> [Profile] {
        do {
            return try await Backend.supabase
                .rpc("matchmaker_candidates", params: PinnedParam(pinned: pinnedID))
                .execute()
                .value
        } catch {
            if error is CancellationError { throw error }
            throw MatchmakerError.unexpected(error)
        }
    }

    /// Likes received vs given for a user (empty-state diagnostic).
    public func likeStats(for userID: UUID) async throws -> LikeStats {
        do {
            let rows: [StatsRow] = try await Backend.supabase
                .rpc("matchmaker_like_stats", params: TargetParam(target: userID))
                .execute()
                .value
            let row = rows.first
            return LikeStats(received: row?.received ?? 0, given: row?.given ?? 0)
        } catch {
            if error is CancellationError { throw error }
            throw MatchmakerError.unexpected(error)
        }
    }

    /// "Next profile" — move the pinned user to the back of the queue (revisit
    /// later) without matching.
    public func requeue(userID: UUID) async throws {
        do {
            try await Backend.supabase
                .rpc("requeue_user", params: TargetParam(target: userID))
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw MatchmakerError.unexpected(error)
        }
    }

    private struct PinnedParam: Encodable { let pinned: UUID }
    private struct TargetParam: Encodable { let target: UUID }
    private struct StatsRow: Decodable { let received: Int; let given: Int }
}
