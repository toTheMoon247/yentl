import Foundation

/// User gender. MVP is heterosexual matching only, so just male/female.
/// Mirrors the `public.gender` Postgres enum.
public enum Gender: String, Codable, CaseIterable, Sendable {
    case male
    case female

    /// Human-readable label for pickers and profile display.
    public var displayName: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        }
    }
}

/// A user's dating profile.
///
/// Slice 1 covers the basics only; later slices add bio, prompts, interests,
/// photos, and the hidden matchmaker fields (height, income). `dateOfBirth`
/// is an ISO `yyyy-MM-dd` string to match the Postgres `date` column exactly
/// (no timezone ambiguity).
public struct Profile: Codable, Sendable {
    public let id: UUID
    public var displayName: String
    public var dateOfBirth: String
    public var gender: Gender
    public var location: String
    public var profileCompletedAt: Date?

    public init(
        id: UUID,
        displayName: String,
        dateOfBirth: String,
        gender: Gender,
        location: String,
        profileCompletedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.dateOfBirth = dateOfBirth
        self.gender = gender
        self.location = location
        self.profileCompletedAt = profileCompletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case dateOfBirth = "date_of_birth"
        case gender
        case location
        case profileCompletedAt = "profile_completed_at"
    }
}
