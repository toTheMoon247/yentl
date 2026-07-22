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

    /// Every match a given user was part of, newest first, from that user's
    /// perspective (Match History screen).
    public func matchHistory(for userID: UUID) async throws -> [MatchHistoryEntry] {
        do {
            return try await Backend.supabase
                .rpc("match_history_for_user", params: TargetParam(target: userID))
                .execute()
                .value
        } catch {
            if error is CancellationError { throw error }
            throw MatchmakerError.unexpected(error)
        }
    }

    /// The latest matches across all users, newest first (Recent Matches
    /// dashboard). The server clamps `limit` to 1...200.
    public func recentMatches(limit: Int = 50) async throws -> [RecentMatchEntry] {
        do {
            return try await Backend.supabase
                .rpc("recent_matches", params: LimitParams(limitCount: limit))
                .execute()
                .value
        } catch {
            if error is CancellationError { throw error }
            throw MatchmakerError.unexpected(error)
        }
    }

    // MARK: - Profile approvals (Phase 12)

    /// Count behind the Approvals tab badge. Kept fresh by
    /// `pendingReviewProfiles()` / `refreshPendingReviewCount()`; 0 hides the
    /// badge.
    public private(set) var pendingReviewCount = 0

    /// Completed profiles the AI flagged for human review, newest-flagged
    /// first (the Approvals tab queue). AI-clean profiles auto-approve and
    /// never appear here.
    public func pendingReviewProfiles() async throws -> [PendingReviewProfile] {
        do {
            let rows: [PendingReviewProfile] = try await Backend.supabase
                .rpc("pending_review_profiles")
                .execute()
                .value
            pendingReviewCount = rows.count
            return rows
        } catch {
            if error is CancellationError { throw error }
            throw MatchmakerError.unexpected(error)
        }
    }

    /// Badge-only refresh (e.g. on tab-bar appearance). Swallows errors — a
    /// failed badge poll must never surface UI errors outside the tab.
    public func refreshPendingReviewCount() async {
        _ = try? await pendingReviewProfiles()
    }

    /// Approve a flagged profile — it goes live (and enqueues for matching).
    public func approveProfile(_ profileID: UUID, note: String? = nil) async throws {
        do {
            try await Backend.supabase
                .rpc("matchmaker_approve_profile",
                     params: ApproveParams(target: profileID, note: note))
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw MatchmakerError.unexpected(error)
        }
    }

    /// Reject a flagged profile. `reason` is required by the RPC — build it
    /// with `ProfileRejectionReason.reasonText(note:)`.
    public func rejectProfile(_ profileID: UUID, reason: String) async throws {
        do {
            try await Backend.supabase
                .rpc("matchmaker_reject_profile",
                     params: RejectParams(target: profileID, reason: reason))
                .execute()
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

    /// Internal (not private) so the snake-case key is unit-tested — a drifted
    /// CodingKey would silently fall back to the server-side default limit.
    struct LimitParams: Encodable {
        let limitCount: Int
        enum CodingKeys: String, CodingKey {
            case limitCount = "limit_count"
        }
    }

    /// Internal (not private) so the key names + nil-note omission are
    /// unit-tested: a drifted key would make the RPC call fail (or silently
    /// drop the note), and an explicit-null note must stay omitted so the
    /// server-side default applies.
    struct ApproveParams: Encodable {
        let target: UUID
        let note: String?
    }

    struct RejectParams: Encodable {
        let target: UUID
        let reason: String
    }
}
