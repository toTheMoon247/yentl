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

/// A single profile photo. The image bytes live in the `profile-photos`
/// Storage bucket at `storagePath`; this is the database row describing it.
/// `orderIndex` is the display order (0 = first).
public struct ProfilePhoto: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let userId: UUID
    public var storagePath: String
    public var orderIndex: Int

    public init(id: UUID, userId: UUID, storagePath: String, orderIndex: Int) {
        self.id = id
        self.userId = userId
        self.storagePath = storagePath
        self.orderIndex = orderIndex
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case storagePath = "storage_path"
        case orderIndex = "order_index"
    }
}
