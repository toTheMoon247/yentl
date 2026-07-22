import XCTest
@testable import YentlShared

final class ProfileReviewTests: XCTestCase {
    // MARK: - ProfileReviewState raw values

    /// The Swift cases must track the `public.profile_review_state` Postgres
    /// enum labels exactly — a drift here silently misroutes the account
    /// stage (e.g. an under-review user landing in the full app).
    func testReviewStateRawValuesMatchPostgresEnum() {
        XCTAssertEqual(ProfileReviewState.draft.rawValue, "draft")
        XCTAssertEqual(ProfileReviewState.pendingAI.rawValue, "pending_ai")
        XCTAssertEqual(ProfileReviewState.pendingReview.rawValue, "pending_review")
        XCTAssertEqual(ProfileReviewState.live.rawValue, "live")
        XCTAssertEqual(ProfileReviewState.rejected.rawValue, "rejected")
    }

    /// An unknown label (a future state) maps to nil, not a crash/throw —
    /// ProfileService degrades it to "no gate".
    func testUnknownReviewStateIsNil() {
        XCTAssertNil(ProfileReviewState(rawValue: "suspended"))
    }

    // MARK: - MyModerationStatus decoding

    /// Decodes the owner-readable projection of `profile_moderation` exactly
    /// as PostgREST serialises `select decision, decision_reason`.
    func testModerationStatusDecodesRejectedRow() throws {
        let json = """
        {
            "decision": "rejected",
            "decision_reason": "contact_info_in_bio: Please remove the phone number."
        }
        """
        let status = try JSONDecoder().decode(MyModerationStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.decision, "rejected")
        XCTAssertEqual(status.decisionReason,
                       "contact_info_in_bio: Please remove the phone number.")
    }

    /// A pure-AI row (no human decision yet) has nulls in both columns.
    func testModerationStatusDecodesUndecidedRow() throws {
        let json = """
        {"decision": null, "decision_reason": null}
        """
        let status = try JSONDecoder().decode(MyModerationStatus.self, from: Data(json.utf8))
        XCTAssertNil(status.decision)
        XCTAssertNil(status.decisionReason)
    }

    // MARK: - screen-profile request encoding

    /// The Edge Function validates `profile_id` against a LOWERCASE-only UUID
    /// regex, while `UUID.uuidString` is uppercase — the request must encode
    /// the lowercased form under the snake_case key.
    func testScreenProfileRequestEncodesLowercasedSnakeCase() throws {
        let id = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        let data = try JSONEncoder().encode(ProfileService.ScreenProfileRequest(profileID: id))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        XCTAssertEqual(object, ["profile_id": "abcdef01-2345-6789-abcd-ef0123456789"])
    }

    // MARK: - RejectionFeedback parsing

    func testParseBareToken() {
        let feedback = RejectionFeedback.parse("inappropriate_photos")
        XCTAssertEqual(feedback.reason, .inappropriatePhotos)
        XCTAssertNil(feedback.note)
    }

    func testParseTokenWithNote() {
        let feedback = RejectionFeedback.parse(
            "contact_info_in_bio: Please drop the Instagram handle."
        )
        XCTAssertEqual(feedback.reason, .contactInfoInBio)
        XCTAssertEqual(feedback.note, "Please drop the Instagram handle.")
    }

    /// A note containing further colons stays intact — only the FIRST
    /// token-delimiting colon splits.
    func testParseNoteKeepsInnerColons() {
        let feedback = RejectionFeedback.parse("other: See rule 4: no group shots.")
        XCTAssertEqual(feedback.reason, .other)
        XCTAssertEqual(feedback.note, "See rule 4: no group shots.")
    }

    /// "token:" with an empty note behaves like the bare token.
    func testParseTokenWithEmptyNote() {
        let feedback = RejectionFeedback.parse("not_a_single_person:   ")
        XCTAssertEqual(feedback.reason, .notASinglePerson)
        XCTAssertNil(feedback.note)
    }

    /// Unrecognised text (a matchmaker typed something free-form) becomes the
    /// note on top of the generic message — never dropped, never crashes.
    func testParseUnknownTextBecomesNote() {
        let feedback = RejectionFeedback.parse("Photos are too blurry to verify.")
        XCTAssertNil(feedback.reason)
        XCTAssertEqual(feedback.note, "Photos are too blurry to verify.")
        XCTAssertEqual(feedback.message, ProfileRejectionReason.other.userFacingMessage)
    }

    func testParseNilAndEmpty() {
        XCTAssertEqual(RejectionFeedback.parse(nil),
                       RejectionFeedback(reason: nil, note: nil))
        XCTAssertEqual(RejectionFeedback.parse("   "),
                       RejectionFeedback(reason: nil, note: nil))
    }

    /// A prefix must be the whole token, not a lookalike ("contact_info_in_bio"
    /// vs a hypothetical shorter token) — and unknown tokens with colons still
    /// land as free text.
    func testParseUnknownTokenWithColonIsFreeText() {
        let feedback = RejectionFeedback.parse("spam_account: repeated signups")
        XCTAssertNil(feedback.reason)
        XCTAssertEqual(feedback.note, "spam_account: repeated signups")
    }

    // MARK: - User-facing copy

    /// Every canned token has non-empty, friendly copy that never leaks the
    /// raw token text or internal state names.
    func testUserFacingMessagesAreFriendly() {
        for reason in ProfileRejectionReason.allCases {
            let message = reason.userFacingMessage
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains(reason.rawValue),
                           "\(reason) copy leaks its internal token")
            XCTAssertFalse(message.lowercased().contains("rejected"),
                           "\(reason) copy should stay non-alarming")
            XCTAssertFalse(message.contains("_"),
                           "\(reason) copy looks like it contains an internal slug")
        }
    }

    /// The screen's message uses the parsed token's copy, falling back to
    /// `.other` when no token matched.
    func testFeedbackMessageMapsToken() {
        XCTAssertEqual(RejectionFeedback.parse("inappropriate_photos").message,
                       ProfileRejectionReason.inappropriatePhotos.userFacingMessage)
        XCTAssertEqual(RejectionFeedback.parse(nil).message,
                       ProfileRejectionReason.other.userFacingMessage)
    }
}
