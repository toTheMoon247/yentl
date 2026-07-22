import XCTest
@testable import YentlShared

final class NotificationPreferencesServiceTests: XCTestCase {
    /// The upsert payload must serialize to the exact snake_case column names
    /// of public.notification_preferences — a drifted key would make every
    /// settings write fail server-side.
    func testUpsertPayloadEncodesSnakeCaseKeys() throws {
        let userID = UUID()
        let data = try JSONEncoder().encode(
            NotificationPreferencesService.UpsertPayload(
                userId: userID, matchPushes: false, messagePushes: true
            )
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(json.keys), ["user_id", "match_pushes", "message_pushes"])
        XCTAssertEqual(json["user_id"] as? String, userID.uuidString)
        XCTAssertEqual(json["match_pushes"] as? Bool, false)
        XCTAssertEqual(json["message_pushes"] as? Bool, true)
    }

    /// No stored row means opted in to everything — the invariant every
    /// reader (notify function, ChatService gating, settings screen) assumes.
    func testDefaultsAreBothOn() {
        XCTAssertTrue(NotificationPreferences.defaults.matchPushes)
        XCTAssertTrue(NotificationPreferences.defaults.messagePushes)
    }
}
