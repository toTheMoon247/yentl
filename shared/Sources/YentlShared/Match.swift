import Foundation

/// State of a match. Mirrors the `public.match_state` Postgres enum.
public enum MatchState: String, Codable, Sendable {
    case pending
    case confirmed
    case rejected
    case expired
    /// A participant blocked the other person. Terminal; hidden from both
    /// sides' match lists (my_matches excludes it server-side).
    case blocked
}

/// Canned reasons for reporting a user. Raw values mirror the
/// `reports.reason` check constraint — changing one requires a migration.
public enum ReportReason: String, CaseIterable, Codable, Sendable, Identifiable {
    case harassment
    case inappropriatePhotos = "inappropriate_photos"
    case spamScam = "spam_scam"
    case offPlatformContact = "off_platform_contact"
    case other

    public var id: String { rawValue }

    /// Human-readable label for pickers.
    public var label: String {
        switch self {
        case .harassment: return "Harassment or bullying"
        case .inappropriatePhotos: return "Inappropriate photos"
        case .spamScam: return "Spam or scam"
        case .offPlatformContact: return "Pushing to leave Yentl"
        case .other: return "Something else"
        }
    }
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
