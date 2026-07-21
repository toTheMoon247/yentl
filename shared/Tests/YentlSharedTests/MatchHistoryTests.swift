import XCTest
@testable import YentlShared

final class MatchHistoryTests: XCTestCase {
    // MARK: - match_history_for_user decoding

    /// A fully-populated row, exactly as PostgREST serialises the RPC's
    /// snake_case columns. If a CodingKey drifts, decoding fails loudly here
    /// instead of silently in the app.
    func testMatchHistoryEntryDecodesFullRow() throws {
        let json = """
        {
            "match_id": "11111111-2222-3333-4444-555555555555",
            "state": "expired",
            "created_at_epoch": 1752940800.5,
            "expires_at_epoch": 1753027200,
            "resolved_at_epoch": 1753027260,
            "target_response": "accepted",
            "other_response": null,
            "other_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "other_display_name": "Chloe"
        }
        """
        let entry = try JSONDecoder().decode(
            MatchHistoryEntry.self, from: Data(json.utf8)
        )

        XCTAssertEqual(entry.matchID.uuidString, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(entry.state, .expired)
        XCTAssertEqual(entry.createdAtEpoch, 1752940800.5)
        XCTAssertEqual(entry.targetResponse, "accepted")
        XCTAssertNil(entry.otherResponse)
        XCTAssertEqual(entry.otherDisplayName, "Chloe")
        XCTAssertEqual(entry.resolvedAt, Date(timeIntervalSince1970: 1753027260))
        XCTAssertEqual(entry.id, entry.matchID)
    }

    /// The RPC LEFT JOINs profiles: a participant with no profile row yields
    /// null id *and* name, and pending rows have null resolved_at. All three
    /// must decode as nil, never throw or force-unwrap.
    func testMatchHistoryEntryDecodesNullOtherAndPending() throws {
        let json = """
        {
            "match_id": "11111111-2222-3333-4444-555555555555",
            "state": "pending",
            "created_at_epoch": 1752940800,
            "expires_at_epoch": 1753027200,
            "resolved_at_epoch": null,
            "target_response": null,
            "other_response": null,
            "other_id": null,
            "other_display_name": null
        }
        """
        let entry = try JSONDecoder().decode(
            MatchHistoryEntry.self, from: Data(json.utf8)
        )

        XCTAssertEqual(entry.state, .pending)
        XCTAssertNil(entry.resolvedAtEpoch)
        XCTAssertNil(entry.resolvedAt)
        XCTAssertNil(entry.otherID)
        XCTAssertNil(entry.otherDisplayName)
    }

    // MARK: - recent_matches decoding

    func testRecentMatchEntryDecodesFullRow() throws {
        let json = """
        {
            "match_id": "99999999-8888-7777-6666-555555555555",
            "state": "confirmed",
            "created_at_epoch": 1752940800,
            "expires_at_epoch": 1753027200,
            "resolved_at_epoch": 1752944400,
            "user_a_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "user_a_name": "Caleb",
            "user_a_response": "accepted",
            "user_b_id": "FFFFFFFF-0000-1111-2222-333333333333",
            "user_b_name": "Chloe",
            "user_b_response": "accepted"
        }
        """
        let entry = try JSONDecoder().decode(
            RecentMatchEntry.self, from: Data(json.utf8)
        )

        XCTAssertEqual(entry.state, .confirmed)
        XCTAssertEqual(entry.userAName, "Caleb")
        XCTAssertEqual(entry.userBName, "Chloe")
        XCTAssertEqual(entry.userAResponse, "accepted")
        XCTAssertEqual(entry.resolvedAt, Date(timeIntervalSince1970: 1752944400))
        XCTAssertEqual(entry.id, entry.matchID)
    }

    /// Missing profile rows null out either participant's id and name.
    func testRecentMatchEntryDecodesNullParticipants() throws {
        let json = """
        {
            "match_id": "99999999-8888-7777-6666-555555555555",
            "state": "pending",
            "created_at_epoch": 1752940800,
            "expires_at_epoch": 1753027200,
            "resolved_at_epoch": null,
            "user_a_id": null,
            "user_a_name": null,
            "user_a_response": null,
            "user_b_id": null,
            "user_b_name": null,
            "user_b_response": null
        }
        """
        let entry = try JSONDecoder().decode(
            RecentMatchEntry.self, from: Data(json.utf8)
        )

        XCTAssertNil(entry.userAID)
        XCTAssertNil(entry.userAName)
        XCTAssertNil(entry.userBID)
        XCTAssertNil(entry.userBName)
        XCTAssertNil(entry.resolvedAt)
    }

    // MARK: - recent_matches params

    /// The limit param must serialise to the exact snake_case key the RPC
    /// declares; a drifted key would silently fall back to the server default.
    func testLimitParamsEncodesSnakeCaseKey() throws {
        let data = try JSONEncoder().encode(MatchmakerService.LimitParams(limitCount: 25))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(json.keys), ["limit_count"])
        XCTAssertEqual(json["limit_count"] as? Int, 25)
    }
}
