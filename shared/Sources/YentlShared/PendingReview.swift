import Foundation

/// One row of the matchmaker Approvals queue (returned by the staff-only
/// `pending_review_profiles` RPC): a completed profile the AI screening
/// flagged for human review, with the structured moderation reasons.
///
/// Only flagged profiles ever appear here — AI-clean profiles auto-approve
/// and never reach a human (Phase 12 decision, 2026-07-22).
public struct PendingReviewProfile: Codable, Sendable, Identifiable, Hashable {
    public let profileID: UUID
    public let displayName: String
    /// ISO `yyyy-MM-dd`, same convention as `Profile.dateOfBirth`.
    public let dateOfBirth: String
    public let gender: Gender
    public let location: String
    /// When the AI flagged the profile, as epoch seconds (same convention as
    /// `MatchHistoryEntry`).
    public let flaggedAtEpoch: Double
    /// The moderation `reasons` jsonb captured with the flagging verdict.
    /// Empty (all nil) when no moderation snapshot exists.
    public let reasons: ModerationReasons

    public var id: UUID { profileID }
    public var flaggedAt: Date { Date(timeIntervalSince1970: flaggedAtEpoch) }

    public init(
        profileID: UUID,
        displayName: String,
        dateOfBirth: String,
        gender: Gender,
        location: String,
        flaggedAtEpoch: Double,
        reasons: ModerationReasons = ModerationReasons()
    ) {
        self.profileID = profileID
        self.displayName = displayName
        self.dateOfBirth = dateOfBirth
        self.gender = gender
        self.location = location
        self.flaggedAtEpoch = flaggedAtEpoch
        self.reasons = reasons
    }

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case displayName = "display_name"
        case dateOfBirth = "date_of_birth"
        case gender
        case location
        case flaggedAtEpoch = "flagged_at_epoch"
        case reasons
    }
}

public extension PendingReviewProfile {
    /// Age in whole years, derived from `dateOfBirth` (`yyyy-MM-dd`).
    var age: Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let dob = formatter.date(from: dateOfBirth) else { return nil }
        return Calendar.current.dateComponents([.year], from: dob, to: Date()).year
    }
}

/// The structured `reasons` jsonb written by the `screen-profile` Edge
/// Function (via `apply_ai_verdict`). Every field is optional so a
/// matchmaker-created snapshot (`{}`), a partial payload, or a future shape
/// change decodes instead of throwing — an unreadable reason must never hide
/// a flagged profile.
public struct ModerationReasons: Codable, Sendable, Hashable {
    /// Text moderation over name + location + bio + prompt answers.
    public struct TextCheck: Codable, Sendable, Hashable {
        public let flagged: Bool?
        /// OpenAI moderation category slugs, e.g. "sexual", "harassment/threatening".
        public let categories: [String]?

        public init(flagged: Bool? = nil, categories: [String]? = nil) {
            self.flagged = flagged
            self.categories = categories
        }
    }

    /// One hit from the contact-info detector (phone/email/handle/…).
    public struct ContactMatch: Codable, Sendable, Hashable {
        public let kind: String?
        /// A short excerpt of the matched text.
        public let sample: String?

        public init(kind: String? = nil, sample: String? = nil) {
            self.kind = kind
            self.sample = sample
        }
    }

    public struct ContactInfo: Codable, Sendable, Hashable {
        public let flagged: Bool?
        public let matches: [ContactMatch]?

        public init(flagged: Bool? = nil, matches: [ContactMatch]? = nil) {
            self.flagged = flagged
            self.matches = matches
        }
    }

    /// GPT-4o vision: is this one real person's face?
    public struct FaceCheck: Codable, Sendable, Hashable {
        public let facesPresent: Bool?
        public let singlePerson: Bool?
        public let appearsRealPhoto: Bool?
        public let flagged: Bool?
        public let notes: String?

        public init(
            facesPresent: Bool? = nil,
            singlePerson: Bool? = nil,
            appearsRealPhoto: Bool? = nil,
            flagged: Bool? = nil,
            notes: String? = nil
        ) {
            self.facesPresent = facesPresent
            self.singlePerson = singlePerson
            self.appearsRealPhoto = appearsRealPhoto
            self.flagged = flagged
            self.notes = notes
        }

        enum CodingKeys: String, CodingKey {
            case facesPresent = "faces_present"
            case singlePerson = "single_person"
            case appearsRealPhoto = "appears_real_photo"
            case flagged
            case notes
        }
    }

    /// NSFW moderation outcome for one photo.
    public struct PhotoModeration: Codable, Sendable, Hashable {
        public let flagged: Bool?
        public let categories: [String]?

        public init(flagged: Bool? = nil, categories: [String]? = nil) {
            self.flagged = flagged
            self.categories = categories
        }
    }

    /// Per-photo report: either the two check results, or an `error` when the
    /// photo could not be screened. Photos are in display order (photo 1 = the
    /// profile's first photo).
    public struct PhotoReport: Codable, Sendable, Hashable {
        public let photoID: String?
        public let flagged: Bool?
        public let moderation: PhotoModeration?
        public let face: FaceCheck?
        public let error: String?

        public init(
            photoID: String? = nil,
            flagged: Bool? = nil,
            moderation: PhotoModeration? = nil,
            face: FaceCheck? = nil,
            error: String? = nil
        ) {
            self.photoID = photoID
            self.flagged = flagged
            self.moderation = moderation
            self.face = face
            self.error = error
        }

        enum CodingKeys: String, CodingKey {
            case photoID = "photo_id"
            case flagged
            case moderation
            case face
            case error
        }
    }

    public let text: TextCheck?
    public let contactInfo: ContactInfo?
    public let photos: [PhotoReport]?
    public let errors: [String]?

    public init(
        text: TextCheck? = nil,
        contactInfo: ContactInfo? = nil,
        photos: [PhotoReport]? = nil,
        errors: [String]? = nil
    ) {
        self.text = text
        self.contactInfo = contactInfo
        self.photos = photos
        self.errors = errors
    }

    enum CodingKeys: String, CodingKey {
        case text
        case contactInfo = "contact_info"
        case photos
        case errors
    }
}

// MARK: - Human-readable rendering

public extension ModerationReasons {
    /// Short labels for the queue row, worst-first — e.g.
    /// ["Photo flagged", "Contact info"]. Empty when nothing is flagged
    /// (e.g. a missing snapshot).
    var flagSummaries: [String] {
        var labels: [String] = []
        let photoReports = photos ?? []
        if photoReports.contains(where: { $0.moderation?.flagged == true }) {
            labels.append("Photo flagged")
        }
        let faces = photoReports.compactMap(\.face)
        if faces.contains(where: { $0.singlePerson == false }) {
            labels.append("Not a single person")
        }
        if faces.contains(where: { $0.facesPresent == false }) {
            labels.append("No face visible")
        }
        if faces.contains(where: { $0.appearsRealPhoto == false }) {
            labels.append("Not a real photo")
        }
        if contactInfo?.flagged == true { labels.append("Contact info") }
        if text?.flagged == true { labels.append("Text flagged") }
        if !(errors ?? []).isEmpty { labels.append("Screening error") }
        return labels
    }

    /// Full human-readable lines for the detail screen's "why was this
    /// flagged" panel — the jsonb reasons mapped to plain English.
    var detailLines: [String] {
        var lines: [String] = []
        for (index, photo) in (photos ?? []).enumerated() {
            let name = "Photo \(index + 1)"
            if let moderation = photo.moderation, moderation.flagged == true {
                lines.append("\(name): content flagged"
                             + Self.categoryList(moderation.categories))
            }
            if let face = photo.face, face.flagged == true {
                var problems: [String] = []
                if face.facesPresent == false { problems.append("no face visible") }
                if face.singlePerson == false { problems.append("more than one person") }
                if face.appearsRealPhoto == false { problems.append("doesn't look like a real photo") }
                var line = "\(name): " + (problems.isEmpty
                    ? "face check flagged" : problems.joined(separator: ", "))
                if let notes = face.notes, !notes.isEmpty { line += " — \(notes)" }
                lines.append(line)
            }
            if let error = photo.error, !error.isEmpty {
                lines.append("\(name): could not be screened (\(error))")
            }
        }
        if let contact = contactInfo, contact.flagged == true {
            let hits = (contact.matches ?? []).map { match -> String in
                let kind = Self.contactKindLabel(match.kind)
                if let sample = match.sample, !sample.isEmpty {
                    return "\(kind) (\u{201C}\(sample)\u{201D})"
                }
                return kind
            }
            lines.append("Contact info in text"
                         + (hits.isEmpty ? "" : ": " + hits.joined(separator: ", ")))
        }
        if let text, text.flagged == true {
            lines.append("Profile text flagged" + Self.categoryList(text.categories))
        }
        if let errors, !errors.isEmpty {
            lines.append("Some checks failed — the AI review is incomplete "
                         + "(\(errors.count) error\(errors.count == 1 ? "" : "s"))")
        }
        return lines
    }

    /// ": sexual content, harassment (threatening)" — or "" when empty.
    private static func categoryList(_ categories: [String]?) -> String {
        let readable = (categories ?? []).map(categoryLabel)
        return readable.isEmpty ? "" : ": " + readable.joined(separator: ", ")
    }

    /// OpenAI moderation slugs → plain English, e.g.
    /// "harassment/threatening" → "harassment (threatening)".
    private static func categoryLabel(_ slug: String) -> String {
        let parts = slug.split(separator: "/")
            .map { $0.replacingOccurrences(of: "-", with: " ")
                     .replacingOccurrences(of: "_", with: " ") }
        guard let first = parts.first else { return slug }
        if parts.count == 1 { return first == "sexual" ? "sexual content" : first }
        return "\(first) (\(parts.dropFirst().joined(separator: ", ")))"
    }

    private static func contactKindLabel(_ kind: String?) -> String {
        switch kind {
        case "email": return "email address"
        case "phone": return "phone number"
        case "url": return "link"
        case "handle": return "@handle"
        case "social_platform": return "social platform mention"
        case "off_platform_invite": return "off-platform invite"
        case let other?: return other.replacingOccurrences(of: "_", with: " ")
        case nil: return "contact info"
        }
    }
}

/// Canned rejection reasons for the Approvals detail screen. The raw value is
/// the stable token sent to `matchmaker_reject_profile` and stored in
/// `profile_moderation.decision_reason` (with the matchmaker's optional note
/// appended as "token: note"), so the Slice 3 consumer "profile rejected"
/// screen can prefix-match the token and show its own user-facing copy.
public enum ProfileRejectionReason: String, CaseIterable, Sendable, Identifiable {
    case inappropriatePhotos = "inappropriate_photos"
    case notASinglePerson = "not_a_single_person"
    case contactInfoInBio = "contact_info_in_bio"
    case incompleteOrFake = "incomplete_or_fake"
    case other

    public var id: String { rawValue }

    /// Label shown to the matchmaker in the reason picker.
    public var displayName: String {
        switch self {
        case .inappropriatePhotos: return "Inappropriate photos"
        case .notASinglePerson: return "Not a single person"
        case .contactInfoInBio: return "Contact info in bio"
        case .incompleteOrFake: return "Incomplete or fake"
        case .other: return "Other"
        }
    }

    /// The reason text sent to `matchmaker_reject_profile`: the stable token,
    /// with the matchmaker's note appended when present.
    public func reasonText(note: String?) -> String {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? rawValue : "\(rawValue): \(trimmed)"
    }
}
