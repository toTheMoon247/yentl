import XCTest
@testable import YentlShared

final class MatchServiceTests: XCTestCase {
    /// The create_match RPC params must serialize to the exact snake_case keys
    /// PostgREST expects. If a CodingKey drifts, the RPC silently misses an
    /// argument (e.g. expires_in_seconds) and the server falls back to 24h.
    func testCreateParamsEncodesSnakeCaseKeys() throws {
        let one = UUID()
        let two = UUID()
        let params = MatchService.CreateParams(
            userOne: one, userTwo: two, expiresInSeconds: 300
        )

        let data = try JSONEncoder().encode(params)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(json.keys), ["user_one", "user_two", "expires_in_seconds"])
        XCTAssertEqual(json["user_one"] as? String, one.uuidString)
        XCTAssertEqual(json["user_two"] as? String, two.uuidString)
        XCTAssertEqual(json["expires_in_seconds"] as? Int, 300)
    }

    /// block_match's params: exact arg names, and nil optionals OMITTED (not
    /// null) so the RPC's SQL defaults apply — PostgREST resolves the function
    /// by the named-argument subset.
    func testBlockParamsEncodesKeysAndOmitsNils() throws {
        let matchID = UUID()

        let full = try encodeToJSON(MatchService.BlockParams(
            match: matchID, reason: "harassment", note: "a note"
        ))
        XCTAssertEqual(Set(full.keys), ["match", "reason", "note"])
        XCTAssertEqual(full["match"] as? String, matchID.uuidString)
        XCTAssertEqual(full["reason"] as? String, "harassment")

        let bare = try encodeToJSON(MatchService.BlockParams(
            match: matchID, reason: nil, note: nil
        ))
        XCTAssertEqual(Set(bare.keys), ["match"], "nil reason/note must be omitted")
    }

    func testReportParamsEncodesKeysAndOmitsNils() throws {
        let reported = UUID()
        let matchID = UUID()

        let full = try encodeToJSON(MatchService.ReportParams(
            reported: reported, reason: "spam_scam", match: matchID, note: "hi"
        ))
        XCTAssertEqual(Set(full.keys), ["reported", "reason", "match", "note"])
        XCTAssertEqual(full["reported"] as? String, reported.uuidString)

        let bare = try encodeToJSON(MatchService.ReportParams(
            reported: reported, reason: "other", match: nil, note: nil
        ))
        XCTAssertEqual(Set(bare.keys), ["reported", "reason"])
    }

    /// The canned reasons must match the reports.reason check constraint in
    /// the database, or every report with that reason fails server-side.
    func testReportReasonRawValuesMatchDatabaseConstraint() {
        XCTAssertEqual(
            Set(ReportReason.allCases.map(\.rawValue)),
            ["harassment", "inappropriate_photos", "spam_scam",
             "off_platform_contact", "other"]
        )
    }

    /// Free-text notes are trimmed, and whitespace-only becomes nil so the
    /// server stores null rather than "".
    func testNoteNormalization() {
        XCTAssertNil(MatchService.normalized(nil))
        XCTAssertNil(MatchService.normalized(""))
        XCTAssertNil(MatchService.normalized("   \n"))
        XCTAssertEqual(MatchService.normalized("  hey \n"), "hey")
    }

    private func encodeToJSON(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
