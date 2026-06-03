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
    public var bio: String?
    public var interests: [String]
    /// Hidden matchmaker field — height in centimetres.
    public var heightCm: Int?
    /// Hidden matchmaker field — annual income.
    public var incomeAnnual: Int?
    public var profileCompletedAt: Date?

    public init(
        id: UUID,
        displayName: String,
        dateOfBirth: String,
        gender: Gender,
        location: String,
        bio: String? = nil,
        interests: [String] = [],
        heightCm: Int? = nil,
        incomeAnnual: Int? = nil,
        profileCompletedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.dateOfBirth = dateOfBirth
        self.gender = gender
        self.location = location
        self.bio = bio
        self.interests = interests
        self.heightCm = heightCm
        self.incomeAnnual = incomeAnnual
        self.profileCompletedAt = profileCompletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case dateOfBirth = "date_of_birth"
        case gender
        case location
        case bio
        case interests
        case heightCm = "height_cm"
        case incomeAnnual = "income_annual"
        case profileCompletedAt = "profile_completed_at"
    }
}

/// A user's answered prompt (question chosen from a preset list + answer).
public struct ProfilePrompt: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let userId: UUID
    public var prompt: String
    public var answer: String
    public var orderIndex: Int

    public init(id: UUID, userId: UUID, prompt: String, answer: String, orderIndex: Int) {
        self.id = id
        self.userId = userId
        self.prompt = prompt
        self.answer = answer
        self.orderIndex = orderIndex
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case prompt
        case answer
        case orderIndex = "order_index"
    }
}

/// Input for saving a prompt during profile creation (before it has an id).
public struct ProfilePromptDraft: Sendable, Equatable {
    public var prompt: String
    public var answer: String

    public init(prompt: String, answer: String) {
        self.prompt = prompt
        self.answer = answer
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
