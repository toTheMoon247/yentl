import XCTest
@testable import YentlShared

final class PendingReviewTests: XCTestCase {
    // MARK: - pending_review_profiles decoding

    /// A fully-populated row, exactly as PostgREST serialises the RPC's
    /// snake_case columns — with a realistic `reasons` payload straight from
    /// the screen-profile Edge Function's aggregation shape.
    func testPendingReviewProfileDecodesFullRow() throws {
        let json = """
        {
            "profile_id": "11111111-2222-3333-4444-555555555555",
            "display_name": "Ava",
            "date_of_birth": "1995-01-01",
            "gender": "female",
            "location": "Tel Aviv",
            "flagged_at_epoch": 1753257600.25,
            "reasons": {
                "text": {"flagged": false, "categories": [], "parts_checked": 3},
                "contact_info": {
                    "flagged": true,
                    "matches": [{"kind": "phone", "sample": "054-1234567"}]
                },
                "photos": [
                    {
                        "photo_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                        "flagged": true,
                        "moderation": {"flagged": false, "categories": []},
                        "face": {
                            "faces_present": true,
                            "single_person": false,
                            "appears_real_photo": true,
                            "flagged": true,
                            "notes": "Two people are visible."
                        }
                    }
                ],
                "photos_checked": 1,
                "errors": [],
                "models": {"moderation": "omni-moderation-latest", "vision": "gpt-4o"}
            }
        }
        """
        let entry = try JSONDecoder().decode(
            PendingReviewProfile.self, from: Data(json.utf8)
        )

        XCTAssertEqual(entry.profileID.uuidString, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(entry.id, entry.profileID)
        XCTAssertEqual(entry.displayName, "Ava")
        XCTAssertEqual(entry.gender, .female)
        XCTAssertEqual(entry.location, "Tel Aviv")
        XCTAssertEqual(entry.flaggedAt, Date(timeIntervalSince1970: 1753257600.25))
        XCTAssertEqual(entry.reasons.contactInfo?.flagged, true)
        XCTAssertEqual(entry.reasons.contactInfo?.matches?.first?.kind, "phone")
        XCTAssertEqual(entry.reasons.photos?.count, 1)
        XCTAssertEqual(entry.reasons.photos?.first?.face?.singlePerson, false)
    }

    /// A missing moderation snapshot comes back as `reasons: {}` from the RPC
    /// (LEFT JOIN) — every nested field must decode as nil, never throw, and
    /// the summaries must be empty rather than invented.
    func testPendingReviewProfileDecodesEmptyReasons() throws {
        let json = """
        {
            "profile_id": "11111111-2222-3333-4444-555555555555",
            "display_name": "Ben",
            "date_of_birth": "1990-06-15",
            "gender": "male",
            "location": "Haifa",
            "flagged_at_epoch": 1753257600,
            "reasons": {}
        }
        """
        let entry = try JSONDecoder().decode(
            PendingReviewProfile.self, from: Data(json.utf8)
        )

        XCTAssertNil(entry.reasons.text)
        XCTAssertNil(entry.reasons.contactInfo)
        XCTAssertNil(entry.reasons.photos)
        XCTAssertNil(entry.reasons.errors)
        XCTAssertEqual(entry.reasons.flagSummaries, [])
        XCTAssertEqual(entry.reasons.detailLines, [])
    }

    // MARK: - Human-readable rendering

    func testFlagSummariesCoverEachCheck() {
        let reasons = ModerationReasons(
            text: .init(flagged: true, categories: ["harassment"]),
            contactInfo: .init(flagged: true, matches: [.init(kind: "phone", sample: "054")]),
            photos: [
                .init(flagged: true,
                      moderation: .init(flagged: true, categories: ["sexual"]),
                      face: .init(facesPresent: true, singlePerson: false,
                                  appearsRealPhoto: true, flagged: true))
            ],
            errors: ["photo x: could not sign URL"]
        )

        XCTAssertEqual(reasons.flagSummaries, [
            "Photo flagged",
            "Not a single person",
            "Contact info",
            "Text flagged",
            "Screening error",
        ])
    }

    /// Un-flagged checks must not produce chips — only true flags render.
    func testFlagSummariesIgnoreCleanChecks() {
        let reasons = ModerationReasons(
            text: .init(flagged: false, categories: []),
            contactInfo: .init(flagged: false, matches: []),
            photos: [
                .init(flagged: false,
                      moderation: .init(flagged: false, categories: []),
                      face: .init(facesPresent: true, singlePerson: true,
                                  appearsRealPhoto: true, flagged: false))
            ],
            errors: []
        )
        XCTAssertEqual(reasons.flagSummaries, [])
        XCTAssertEqual(reasons.detailLines, [])
    }

    func testDetailLinesReadAsPlainEnglish() {
        let reasons = ModerationReasons(
            text: .init(flagged: true, categories: ["sexual", "harassment/threatening"]),
            contactInfo: .init(flagged: true, matches: [
                .init(kind: "phone", sample: "054-1234567"),
                .init(kind: "social_platform", sample: "instagram"),
            ]),
            photos: [
                .init(flagged: false,
                      moderation: .init(flagged: false, categories: []),
                      face: .init(facesPresent: true, singlePerson: true,
                                  appearsRealPhoto: true, flagged: false)),
                .init(flagged: true,
                      moderation: .init(flagged: true, categories: ["sexual"]),
                      face: .init(facesPresent: false, singlePerson: true,
                                  appearsRealPhoto: false, flagged: true,
                                  notes: "Appears to be a screenshot.")),
                .init(photoID: "x", error: "could not sign URL"),
            ],
            errors: ["photo x: could not sign URL"]
        )

        XCTAssertEqual(reasons.detailLines, [
            "Photo 2: content flagged: sexual content",
            "Photo 2: no face visible, doesn't look like a real photo — Appears to be a screenshot.",
            "Photo 3: could not be screened (could not sign URL)",
            "Contact info in text: phone number (\u{201C}054-1234567\u{201D}), "
                + "social platform mention (\u{201C}instagram\u{201D})",
            "Profile text flagged: sexual content, harassment (threatening)",
            "Some checks failed — the AI review is incomplete (1 error)",
        ])
    }

    // MARK: - Rejection reasons

    func testRejectionReasonTextAppendsNote() {
        XCTAssertEqual(
            ProfileRejectionReason.inappropriatePhotos.reasonText(note: nil),
            "inappropriate_photos"
        )
        XCTAssertEqual(
            ProfileRejectionReason.notASinglePerson.reasonText(note: "   "),
            "not_a_single_person"
        )
        XCTAssertEqual(
            ProfileRejectionReason.other.reasonText(note: " Group shots only. "),
            "other: Group shots only."
        )
    }

    // MARK: - RPC param encodings

    /// Approve/reject params must serialise to the exact snake_case arg names
    /// the RPCs declare; a drifted key fails the call (or silently drops the
    /// note). A nil note must OMIT the key so the server default applies.
    func testApproveParamsEncodesKeysAndOmitsNilNote() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let withNote = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                MatchmakerService.ApproveParams(target: id, note: "fine")
            )
        ) as? [String: Any])
        XCTAssertEqual(Set(withNote.keys), ["target", "note"])
        XCTAssertEqual(withNote["note"] as? String, "fine")

        let withoutNote = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                MatchmakerService.ApproveParams(target: id, note: nil)
            )
        ) as? [String: Any])
        XCTAssertEqual(Set(withoutNote.keys), ["target"])
    }

    func testRejectParamsEncodesKeys() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                MatchmakerService.RejectParams(target: id, reason: "inappropriate_photos")
            )
        ) as? [String: Any])

        XCTAssertEqual(Set(json.keys), ["target", "reason"])
        XCTAssertEqual(json["reason"] as? String, "inappropriate_photos")
        XCTAssertEqual(
            (json["target"] as? String)?.lowercased(),
            "11111111-2222-3333-4444-555555555555"
        )
    }
}
