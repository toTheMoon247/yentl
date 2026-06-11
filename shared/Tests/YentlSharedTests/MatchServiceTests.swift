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
}
