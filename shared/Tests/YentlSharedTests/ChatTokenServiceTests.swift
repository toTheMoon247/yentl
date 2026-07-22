import XCTest
@testable import YentlShared

final class ChatTokenServiceTests: XCTestCase {
    /// Decodes the exact payload shape the stream-token Edge Function
    /// returns. If a CodingKey drifts from the function's snake_case keys,
    /// decoding fails loudly here instead of silently in the app.
    func testStreamTokenResponseDecodesFunctionPayload() throws {
        let json = """
        {
            "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature",
            "user_id": "11111111-2222-3333-4444-555555555555",
            "expires_at": 1753203600
        }
        """
        let response = try JSONDecoder().decode(
            StreamTokenResponse.self, from: Data(json.utf8)
        )

        XCTAssertEqual(
            response.token,
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature"
        )
        XCTAssertEqual(response.userID.uuidString, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(response.expiresAtEpoch, 1753203600)
        XCTAssertEqual(response.expiresAt, Date(timeIntervalSince1970: 1753203600))
    }

    /// A payload missing the token (e.g. an error body that slipped through
    /// with a 200) must throw, never produce a half-formed response.
    func testStreamTokenResponseRejectsMissingToken() {
        let json = """
        {
            "user_id": "11111111-2222-3333-4444-555555555555",
            "expires_at": 1753203600
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(StreamTokenResponse.self, from: Data(json.utf8))
        )
    }
}
