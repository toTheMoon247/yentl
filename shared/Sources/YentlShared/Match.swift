import Foundation

/// State of a match. Mirrors the `public.match_state` Postgres enum.
public enum MatchState: String, Codable, Sendable {
    case pending
    case confirmed
    case rejected
    case expired
}

/// A match from the current user's perspective, joined to the other person's
/// public profile (returned by the `my_matches` RPC).
public struct MatchSummary: Codable, Sendable, Identifiable {
    public let matchID: UUID
    public let state: MatchState
    /// Expiry as seconds since 1970 (epoch) — avoids timestamp-parsing edge cases.
    public let expiresAtEpoch: Double
    /// "accepted" / "rejected" / nil if the current user hasn't responded.
    public let myResponse: String?
    public let otherID: UUID
    public let otherDisplayName: String
    public let otherDateOfBirth: String
    public let otherGender: Gender
    public let otherLocation: String
    public let otherBio: String?
    public let otherInterests: [String]

    public var id: UUID { matchID }

    public var hasResponded: Bool { myResponse != nil }

    public var expiresAt: Date { Date(timeIntervalSince1970: expiresAtEpoch) }

    /// The other person as a `Profile` (public fields only) for rendering.
    public var otherProfile: Profile {
        Profile(
            id: otherID,
            displayName: otherDisplayName,
            dateOfBirth: otherDateOfBirth,
            gender: otherGender,
            location: otherLocation,
            bio: otherBio,
            interests: otherInterests
        )
    }

    enum CodingKeys: String, CodingKey {
        case matchID = "match_id"
        case state
        case expiresAtEpoch = "expires_at_epoch"
        case myResponse = "my_response"
        case otherID = "other_id"
        case otherDisplayName = "other_display_name"
        case otherDateOfBirth = "other_date_of_birth"
        case otherGender = "other_gender"
        case otherLocation = "other_location"
        case otherBio = "other_bio"
        case otherInterests = "other_interests"
    }
}
