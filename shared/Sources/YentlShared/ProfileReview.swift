import Foundation

/// Where a profile stands in the approval lifecycle — mirrors the
/// `public.profile_review_state` Postgres enum (Phase 12).
///
/// While `profile_approval_enabled` is OFF, a completed profile only ever
/// holds `live` (completion writes it directly). With approval ON, completion
/// is coerced to `pendingAI` by the `enforce_review_state` trigger, AI
/// screening moves it to `live` (clean) or `pendingReview` (flagged), and a
/// matchmaker decision lands on `live` or `rejected`.
public enum ProfileReviewState: String, Codable, Sendable {
    case draft
    case pendingAI = "pending_ai"
    case pendingReview = "pending_review"
    case live
    case rejected
}

/// The owner-readable slice of their own `profile_moderation` row (RLS lets a
/// user select their own row). Carries the latest matchmaker decision and its
/// reason — the input for the consumer "profile needs changes" screen.
public struct MyModerationStatus: Codable, Sendable, Equatable {
    /// "approved" / "rejected", or nil while no human has decided.
    public let decision: String?
    /// For rejections: a canned `ProfileRejectionReason` token, optionally
    /// with the matchmaker's note appended as "token: note". Parse it with
    /// `RejectionFeedback.parse(_:)` — never show it to the user raw.
    public let decisionReason: String?

    public init(decision: String?, decisionReason: String?) {
        self.decision = decision
        self.decisionReason = decisionReason
    }

    enum CodingKeys: String, CodingKey {
        case decision
        case decisionReason = "decision_reason"
    }
}

/// A rejection reason unpacked into user-facing parts: the canned token
/// mapped to warm, actionable copy, plus the matchmaker's optional note.
/// This is the ONLY path from `profile_moderation.decision_reason` to the
/// screen — internal tokens are never shown raw.
public struct RejectionFeedback: Sendable, Equatable {
    /// The canned reason, when the stored text starts with a known token.
    public let reason: ProfileRejectionReason?
    /// The matchmaker's free-text note ("token: note"), or — when the stored
    /// text matches no token at all — the whole stored text, which can only
    /// have been typed by a matchmaker.
    public let note: String?

    public init(reason: ProfileRejectionReason?, note: String?) {
        self.reason = reason
        self.note = note
    }

    /// Splits "token" / "token: note" / free text into its parts.
    public static func parse(_ decisionReason: String?) -> RejectionFeedback {
        let text = decisionReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return RejectionFeedback(reason: nil, note: nil) }
        for token in ProfileRejectionReason.allCases {
            if text == token.rawValue {
                return RejectionFeedback(reason: token, note: nil)
            }
            if text.hasPrefix(token.rawValue + ":") {
                let note = text.dropFirst(token.rawValue.count + 1)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return RejectionFeedback(reason: token, note: note.isEmpty ? nil : note)
            }
        }
        // Unrecognised format — matchmaker-typed text; surface it as the note.
        return RejectionFeedback(reason: nil, note: text)
    }

    /// The friendly, actionable explanation shown on the "profile needs
    /// changes" screen (without the note — the view renders that separately).
    public var message: String {
        (reason ?? .other).userFacingMessage
    }
}

public extension ProfileRejectionReason {
    /// Consumer-facing copy for each canned rejection token: warm, concrete
    /// about what to change, and free of internal wording.
    var userFacingMessage: String {
        switch self {
        case .inappropriatePhotos:
            return "One or more of your photos doesn't fit our photo guidelines. "
                + "Try swapping them for clear, recent photos of yourself."
        case .notASinglePerson:
            return "Your photos should show just you. Pick clear photos where "
                + "you're the only person in the frame and your face is easy to see."
        case .contactInfoInBio:
            return "Profiles can't include contact details — phone numbers, "
                + "email addresses, links, or social handles. Please keep those "
                + "out of your bio and prompt answers; matching happens right here."
        case .incompleteOrFake:
            return "Some parts of your profile look incomplete or were hard to "
                + "verify. Filling everything in fully will help it go through."
        case .other:
            return "A matchmaker took a look and asked for a few changes before "
                + "your profile can go live."
        }
    }
}
