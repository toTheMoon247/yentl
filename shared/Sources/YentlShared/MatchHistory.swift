import Foundation

/// One match in a user's history, from that user's perspective (returned by
/// the staff-only `match_history_for_user` RPC).
///
/// The RPC LEFT JOINs `profiles`, so `otherID` / `otherDisplayName` are nil
/// when the other participant has no profile row — the match itself is never
/// dropped from history.
public struct MatchHistoryEntry: Codable, Sendable, Identifiable {
    public let matchID: UUID
    public let state: MatchState
    /// Timestamps as seconds since 1970 (epoch) — avoids timestamp-parsing
    /// edge cases, same convention as `MatchSummary`.
    public let createdAtEpoch: Double
    public let expiresAtEpoch: Double
    /// Nil while the match is still pending.
    public let resolvedAtEpoch: Double?
    /// "accepted" / "rejected" / nil if the target user never responded.
    public let targetResponse: String?
    public let otherResponse: String?
    public let otherID: UUID?
    public let otherDisplayName: String?

    public var id: UUID { matchID }

    public var createdAt: Date { Date(timeIntervalSince1970: createdAtEpoch) }
    public var expiresAt: Date { Date(timeIntervalSince1970: expiresAtEpoch) }
    public var resolvedAt: Date? { resolvedAtEpoch.map(Date.init(timeIntervalSince1970:)) }

    public init(
        matchID: UUID,
        state: MatchState,
        createdAtEpoch: Double,
        expiresAtEpoch: Double,
        resolvedAtEpoch: Double? = nil,
        targetResponse: String? = nil,
        otherResponse: String? = nil,
        otherID: UUID? = nil,
        otherDisplayName: String? = nil
    ) {
        self.matchID = matchID
        self.state = state
        self.createdAtEpoch = createdAtEpoch
        self.expiresAtEpoch = expiresAtEpoch
        self.resolvedAtEpoch = resolvedAtEpoch
        self.targetResponse = targetResponse
        self.otherResponse = otherResponse
        self.otherID = otherID
        self.otherDisplayName = otherDisplayName
    }

    enum CodingKeys: String, CodingKey {
        case matchID = "match_id"
        case state
        case createdAtEpoch = "created_at_epoch"
        case expiresAtEpoch = "expires_at_epoch"
        case resolvedAtEpoch = "resolved_at_epoch"
        case targetResponse = "target_response"
        case otherResponse = "other_response"
        case otherID = "other_id"
        case otherDisplayName = "other_display_name"
    }
}

/// One row of the matchmaker's recent-matches dashboard (returned by the
/// staff-only `recent_matches` RPC). Same LEFT-JOIN caveat as
/// `MatchHistoryEntry`: either participant's id/name is nil if they have no
/// profile row.
public struct RecentMatchEntry: Codable, Sendable, Identifiable {
    public let matchID: UUID
    public let state: MatchState
    public let createdAtEpoch: Double
    public let expiresAtEpoch: Double
    /// Nil while the match is still pending.
    public let resolvedAtEpoch: Double?
    public let userAID: UUID?
    public let userAName: String?
    /// "accepted" / "rejected" / nil if user A never responded.
    public let userAResponse: String?
    public let userBID: UUID?
    public let userBName: String?
    public let userBResponse: String?

    public var id: UUID { matchID }

    public var createdAt: Date { Date(timeIntervalSince1970: createdAtEpoch) }
    public var expiresAt: Date { Date(timeIntervalSince1970: expiresAtEpoch) }
    public var resolvedAt: Date? { resolvedAtEpoch.map(Date.init(timeIntervalSince1970:)) }

    public init(
        matchID: UUID,
        state: MatchState,
        createdAtEpoch: Double,
        expiresAtEpoch: Double,
        resolvedAtEpoch: Double? = nil,
        userAID: UUID? = nil,
        userAName: String? = nil,
        userAResponse: String? = nil,
        userBID: UUID? = nil,
        userBName: String? = nil,
        userBResponse: String? = nil
    ) {
        self.matchID = matchID
        self.state = state
        self.createdAtEpoch = createdAtEpoch
        self.expiresAtEpoch = expiresAtEpoch
        self.resolvedAtEpoch = resolvedAtEpoch
        self.userAID = userAID
        self.userAName = userAName
        self.userAResponse = userAResponse
        self.userBID = userBID
        self.userBName = userBName
        self.userBResponse = userBResponse
    }

    enum CodingKeys: String, CodingKey {
        case matchID = "match_id"
        case state
        case createdAtEpoch = "created_at_epoch"
        case expiresAtEpoch = "expires_at_epoch"
        case resolvedAtEpoch = "resolved_at_epoch"
        case userAID = "user_a_id"
        case userAName = "user_a_name"
        case userAResponse = "user_a_response"
        case userBID = "user_b_id"
        case userBName = "user_b_name"
        case userBResponse = "user_b_response"
    }
}
